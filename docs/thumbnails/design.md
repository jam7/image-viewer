# サムネイル供給 — プル型パイプライン設計

> Status: 実装完了 (2026-08-02、段階 0〜4)。決定は
> [ADR 011](../adr/011-thumbnail-pull-pipeline.md)、出来上がりの構成は
> [thumbnail_architecture.md](../thumbnail_architecture.md)。
> 本書は不変条件と、その守り方の記録として残す。

ギャラリーのサムネイル供給を「ローダーがリスト順に配る」から「タイルの描画が
要求し、スケジューラが優先度順に応える」に置き換える。動機と実測値、採らな
かった案は ADR 011。ここには構造と規則、進め方を書く。

## 不変条件 (何が変わってはいけないか)

| ID | 条件 | 今どこにあるか |
|---|---|---|
| I1 | 画面に見えたタイルは、いずれ必ず「画像 or 失敗表示」になる (永久スピナー禁止) | 描かれること自体が要求。帳簿が無いので食い違えない |
| I2 | 失敗も答えとして保持する。ただし**確定した失敗**だけ聞き直さない。「まだ無理」(材料が後で揃いうる) は描画のたびに聞き直す | `ThumbnailFailReason.notSupported` / `notYet` の 2 種 |
| I3 | 動画サムネイルは直列で、画像より後。動画再生前にはキャンセルできる | `ThumbnailScheduler._next` + `pauseStills` |
| I4 | Pixiv サムネイル URL の陳腐化時は取り直す ([pixiv_connection.md](../pixiv_connection.md)) | provider.fetchThumbnail 内。**本設計の外、変更なし** |
| I5 | 取得したサムネイルは L2 (ディスク) に永続化される | `ThumbnailScheduler._serve` |
| I6 | まとめ計測ログを出す (性能問題の一次証拠。2026-08-02 の調査で確立) | `wave:` / `pool:` / `frame:` / `metadata:` |

いずれも `test/screens/gallery/thumbnail_supply_test.dart` (読者への約束) と
`test/services/thumbnail/thumbnail_scheduler_test.dart` (スケジューラにしか
守れない分) が固定している。

## 構成

```
ThumbnailOf (タイル 1 つ) ──(1) scheduler.held(item, 距離)──▶ ThumbnailPool
   │ 持っていれば即返す                                        (アプリで 1 つ)
   │ 無ければ want して null (= スピナー)                       ▲ (4) put
   ▼                                                            │
ThumbnailScheduler (場所ごとに 1 つ) ──(3)── L2 (thumb:) → 無ければ fetchThumbnail
   近い順のキュー / 同時 8・取得 5・動画は直列 / フォルダは尋ねない
                                                                │
   (5) プールが id 単位で通知 ──────────────────────────────────┘
```

- **(1)(2) 引く側**: 描かれることが要求。`held` がプールを引き、無ければ
  `want` を積んで null を返す。帯の先読みは `GalleryView._wantThumbnails()`
- **(3) 応える側**: L2 にあれば読み、無ければ取得して L2 に書く (I5)
- **(4)(5) 届け方**: プールに入れ、その id を `watch` しているタイルだけに伝える
- セッション (`GallerySession`) はアイテム列・ページング・anchor・mark を
  持ち続ける。**サムネイルの所有からは外れる**

スケジューラを場所ごとにした理由と、当初案 (アプリで 1 つ) との差は
ADR 011「実装で変えた判断」。

## ThumbnailPool

- キー: アイテム id (キャッシュキー `thumb:<id>` と同じ綴り)。
  値: `ThumbnailResult` (エンコード済みバイト or 失敗)
- **上限はバイト数で 32MB** (定数、ログを見て調整)。成功エントリのバイト数を
  数え、超えたら LRU で押し出す。実測用に件数と総バイトを定期ログ
- 失敗エントリはバイト 0 として数える (押し出しは件数上限 2048 で別途)。
  失敗も「答え」なので、貯めないと同じ失敗を描画のたびに取りに行ってしまう
- **答えは 2 種類**。`notSupported` (確定) は聞き直さない。`notYet` (まだ無理) は
  保持しつつ、描画のたびに聞き直す。「リトライ」という独立した経路は無く、
  初回も再確認も `want` 1 本を通る
- `removeWhere(predicate)`: 「もう一度尋ねさせる」の綴り方 (消せば「答えが無い」に
  戻るので、次の描画が要求する)。`notYet` の導入で常用の呼び出し元は不要になった
- **同じ答えを入れ直したときは通知しない**。しないと、`notYet` を保持 → 通知 →
  再描画 → 再要求 → また `notYet` … で回る
- 通知: `watch(id, cb)` / `unwatch(id, cb)`。プール全体のリスナーは持たない
  (グリッド全面 setState を作らないため)。押し出しとクリアでも通知する ——
  絵を失ったタイルは描き直しで自分から尋ね直す

サムネイルを L1 (`MemoryCache`、10 枚、フル画像と共用) に書くのは**やめる**。
プールがその役割を引き継ぐ。L1 はフル画像専用に戻る。

## ThumbnailScheduler

### 要求と優先度

- **読むのと頼むのは別**。タイルは `thumbnailFor(item)` (プールを引くだけ) と
  `wantThumbnail(item)` (頼む) の 2 つを呼ぶ。「描かれる = 尋ねる」が呼び出し側に
  書いてあるので、繋ぎ忘れて静かに壊れる経路が無い
- `want` はプールの中身だけで動きを決める。同じ id の要求は 1 つにまとめ、
  距離は小さい方を採る:

  | 保持している答え | want |
  |---|---|
  | 何も無い | 積む (初回) |
  | 画像 | 何もしない |
  | `notSupported` / `timeout` | 何もしない (確定) |
  | **`notYet`** | **積む** (材料が揃ったかもしれない) |
  | フォルダ | 何もしない (絵は無い) |
- 優先度は距離だけ。帯は「見えている行 (距離 0) + 前後 1 画面 (距離 1)」で、
  `GalleryView` がスクロール位置と `galleryRowStride(幅)` から計算する。
  固定件数ではないので回転・画面サイズに追従する
- `keepOnly(pred)`: 帯から外れた**未着手**の要求を捨てる。帯に入り直せば
  描画が再要求する
- `cancel()`: ビューが離れた。未着手を捨て、**着手済みは完走させて**プールに
  入れる (捨てても次に来たとき取り直すだけで、完走の方が安い)
- キューの起動はマイクロタスク 1 回にまとめる。帯 80 件で 80 回起動すると
  1 回ごとにキュー全体を走査し、描画スレッドを食う (実測で確認)

### レーン

| レーン | 並列度 | 規則 |
|---|---|---|
| 全体 | 8 (`lanes`) | 近い順に着手 |
| 取得 | 5 (`fetchLanes`) | L2 に無かったものだけ。ディスク読みが共有待ちに並ばないよう、レーン内で更に絞る |
| 動画 | 1 | 画像の要求が尽きてから (I3)。`pauseStills` / `resumeStills` で再生と排他 |

失敗はプールに `ThumbnailFailed` として入れる (I1 の「失敗表示になる」側)。
自動では再試行せず、プールから消えたときに再取得する。

### 計測 (I6)

```
wave: 30 wanted = 1520 held + 0 cached + 30 fetched + 0 failed + 0 dropped, 687ms
pool: 512 entries, 9.9MB
```

`wave` は「要求が積まれてから全部片付くまで」を 1 行にする。**要求した数の
内訳が全部足し合わさる**ようにしてある — 中断した分 (`dropped`) を書かないと、
場所を離れただけの行が不具合に見える (実際に一度そう読んだ)。

## 各シナリオの動き

| シナリオ | 動き |
|---|---|
| 一覧を開く | 可視タイルが要求 → ネット取得 (初回) が優先度順に埋まる。先読み帯が続く |
| スクロール | 見えたタイルが要求 + 帯を追従。通り過ぎた帯外の要求は破棄 |
| タブ切替で戻る | プールに残っていれば**即** (I/O ゼロ)。押し出されていた分だけディスク 8 並列。全 591 件の読み直しはしない |
| ビューア往復 | タブ切替と同じ (プールに残っていれば即)。開いた PDF はキャッシュに載るので、一覧に戻ると `notYet` が聞き直されて表紙になる |
| キャッシュクリア | タイルが描かれるたび要求し直すだけ。帳簿が無いので食い違いも無い (I1) |
| メモリ | 常に 32MB + 失敗エントリ以内。捨てる判断は LRU に一任 |

## 消えるもの / 残るもの

**消える**: `GallerySession.detach/attach` の全捨て・全読み直し、
`_thumbnailResults`、`_resultIds`、配布水位 (`_loadedCount`)、`needsBatchFor`
とタイル側のバッチ起動、`resumeMissingThumbnails`、`retryInterrupted`。

**消えた** (実際に削除済み): 上に加えて `GallerySession.onChanged` と
`GalleryView._repaint` — グリッド全面の再描画そのものが無くなった。

**残る**: ページング (`loadNextPage`、サムネイルと直交)、`ScrollAnchor`、
`ViewerMark`、失敗の型 (`ThumbnailResult` sealed class)、
`VideoThumbnailService`、`SmbProxyServer`、I4 の取り直し。

## 進め方 (各段階でテスト緑 + 実機確認 + commit)

| 段階 | 内容 | 完了条件 |
|---|---|---|
| 0 | **特性テスト** (2026-08-02 完了): `test/screens/gallery/thumbnail_supply_test.dart` 5 件。見えたタイルが埋まる / 離れて戻っても埋まる (再取得なし) / **離れている間にキャッシュを消しても埋まる** / notSupported を描画のたびに取り直さない / 動画は画像の後で 1 本ずつ。`attach` の `resumeMissingThumbnails` を潰すと 3 番目だけが落ちることを確認済み (歯があることの確認) | 現行コードで緑 |
| 1 | **ThumbnailPool 導入** (完了) | 挙動不変で緑。実機で「戻った瞬間に埋まる」を確認 |
| 2 | **スケジューラ + プル化、旧経路の削除** (完了) | 段階 0 の 5 件を無改変で緑。実機で全経路確認 |
| 3 | **項目別通知、帯の間引き** (完了) | サムネイル 1 枚あたりの再構築が約 100 タイル → 1 タイル |
| 4 | **文書** (完了) | ADR 011 Accepted、thumbnail_architecture.md 書き直し |

段階 2 が本体。0/1 は安全網で、2 の途中で壊れたときに「どこまでは正しいか」を
機械が答えられるようにする。

## 分かったこと (2026-08-02 の実測)

- **タブ復帰の 10.5 秒は消えた**。プールに残っていれば I/O ゼロで即描画
- **プル化だけでは「未取得の一覧のスクロールが 3〜5 行で止まる」は直らなかった**。
  主因は別の 2 つ (L2 索引の全書き出し 90ms × 150ms ごと、ページ先読み 200px)。
  ADR 011「この調査で分かった、より大きな 2 つ」を参照
- **フレーム時間の内訳を測るのが決め手だった**。30 秒で 32ms 超が 4 フレーム
  しかないと分かって初めて「描画が重い」筋を捨てられた。build と raster を
  分けて出すこと自体が価値

## 残る検討

- プール上限 32MB の妥当性 (水位ログで判断。サムネイルは長辺 600px /
  400KB 上限なので最悪 80 件、Pixiv の実測は数十 KB で数百件の見込み)
- ディスクレーン並列 8 の妥当性 (実測 18ms/件が並列でどうスケールするか)
- `DiskCache.get` の 18ms/件 — **疑い筋だった `_scheduleFlush` が当たりだった**
  (5 操作ごとの索引全書き出し)。対処後の 1 件あたりは未計測
- **索引の 90ms 自体は残っている** (5 秒に 1 回)。消すには索引を毎回まるごと
  書き直す設計をやめる (追記ジャーナル + たまに圧縮) 必要がある
- **ZIP の読み取り失敗は再起動まで残る**。`notYet` に入れなかったのは、
  聞き直しが Range Read のやり直し = 無料ではないから (`notYet` は「確かめるのが
  無料」に限る、という契約)。一時的な失敗が固定されるのは承知の上で、
  タイルが画面に入るたび共有を読むよりはまし、と判断した

---

# 画素数を表示サイズに合わせる (ADR 012、実装済み・実機確認済み)

決定と理由は [ADR 012](../adr/012-pixels-at-display-size.md)。ここは実装の形。

## GalleryLayout — 1 フレームに 1 つ、数を配る

寸法の計算が `gallery_constants.dart` / `gallery_grid.dart` / `gallery_view.dart` に
散っていて、しかも幅の出どころが 2 種類ある。1 つの値型にまとめる。

```dart
class GalleryLayout {
  final int columns;        // この幅に入る列数
  final double tile;        // タイルの一辺 (dp)。向きで変わらない
  final double spacing;     // 余りを配った列間 (dp)
  final double rowStride;   // tile + spacing
  final int thumbnailPx;    // tile * dpr。L2 に入れる画素数

  factory GalleryLayout.of(double width, Size screen, double dpr);
}
```

- `tile` は `screen.shortestSide` から出す。**回転しても変わらない**
- `columns` は `width` から出す。**回転すると変わる**
- `thumbnailPx` は `tile` から出るので、**端末ごとに 1 つ**

縦画面の列数 (既定 5) は 1 つの定数として持つ。設定から変えられるようにするのは
別タスク (`notes/TODO.md`)。参照は `GalleryLayout.of` の 1 か所だけにしておく。

## 目標画素数をソース層へ渡す

`_thumbnailMaxSize = 600` は `SmbSource` の定数で、端末を知らない。ソース層は
`BuildContext` を持たないので、**呼び出し側が渡す**。

```dart
Future<Uint8List> fetchThumbnail(ImageSource source, {required int targetPx});
Future<Uint8List> fetchFullImage(ImageSource source, {int? maxDisplayPx, ...});
```

- `targetPx`: サムネイルの長辺。`ThumbnailScheduler` が唯一の呼び出し元なので
  そこから渡す
- `maxDisplayPx`: **画素を作るソースだけが使う** (今は PDF のみ)。他のソースは
  元データをそのまま返すので無視してよい。null は「表示サイズを知らない」

アプリ全体のシングルトンに置く案は採らない。値は端末と向きで変わるので、
「いつの値か」が見えない場所に置くと追えなくなる。

## リサイズの判断

`resizeToThumbnail(data, targetPx)` に変える。

- **バイト基準 (400KB) を削除**。画素数が `targetPx` を超えていれば縮める
- `instantiateImageCodecWithSize` の `getTargetSize` は既にあるので、渡す数が
  定数から引数になるだけ
- `PixivSource.fetchThumbnail` も通す (今は素通し)

## 表示側

`Image.memory` に `cacheWidth` を渡す。4 か所:

| 場所 | 渡す値 |
|---|---|
| `pixiv_gallery_body` / `smb_gallery_body` / `favorites_gallery_body` のタイル | `layout.thumbnailPx` |
| `viewer_screen._buildPage` | 画面の物理幅 |

保存側を直しても、既存エントリと元データそのままのソース (SMB のスキャン、
Pixiv の regular) はデコードで効く。**両方要る。**

## PDF

```dart
scale = max(縦画面に収めたときの倍率, 横画面に収めたときの倍率)
```

`_renderPdfThumbnail` は既に `目標 / 長辺` で正しく計算している。ページ側にも
同じ形を持たせる (`scale: 2.0` の定数をやめる)。

## 進め方

各段階でテスト緑 + 実機確認 + commit。**見た目が変わるのは段階 1 だけ**なので、
そこを単独にしておく。

- [x] **段階 0**: `gallery_layout_test.dart` 9 件。幅ごとの列数・stride・
  目標画素数を固定。`gallery_grid_anchor_test.dart` も列数可変を織り込んで更新
- [x] **段階 1**: `GalleryLayout` 導入と列数の可変化 (**挙動変化**: 横画面の見た目)。
  **実機確認が要る唯一の段階**
- [x] **段階 2**: `ThumbnailImage` (タイル 3 か所) とビューアに `cacheWidth`。
  `thumbnail_image_test.dart` 3 件
- [x] **段階 3**: `shrinkToFit(data, targetPx)`。バイト基準を削除し、Pixiv も通す。
  目標画素数は `want` に載せてソース層へ
- [x] **段階 4**: `SmbSource.displayScale`。`pdf_display_scale_test.dart` 5 件。
  効果は既存の計測ログ (`raster + image + png`) で測る

### 実機確認 (2026-08-02、済)

1. 横画面の列数と間隔 — 問題なし
2. サムネイルの鮮明さ — 問題なし
3. PDF のページ送り — **2.6 秒 → 0.45 秒**。数字は ADR 012「実装後の実測」
4. スクロール — 以前から良かったものがそのまま良い

この確認で 1 件クラッシュが出て直した (`shrinkToFit` が `ImageDescriptor` を
コーデックより先に解放し、デコードスレッドが SIGSEGV)。この経路に実画像を通す
テストが 1 つも無かったのが原因で、`thumbnail_resize_test.dart` を追加した。

サムネイルのバイト数が増えることも分かった。次の一手は解像度ではなく圧縮方法で、
ADR 012「残る問題: 圧縮方法」を参照。
