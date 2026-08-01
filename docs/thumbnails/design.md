# サムネイル供給 — プル型パイプライン設計

> Status: 設計確定 ([ADR 011](../adr/011-thumbnail-pull-pipeline.md))、実装未着手。
> 現行実装 (プッシュ型) の記述は [thumbnail_architecture.md](../thumbnail_architecture.md)。
> 実装完了時にそちらを本設計の内容で書き直し、この注記を消す。

ギャラリーのサムネイル供給を「ローダーがリスト順に配る」から「タイルの描画が
要求し、スケジューラが優先度順に応える」に置き換える。動機と実測値、採らな
かった案は ADR 011。ここには構造と規則、進め方を書く。

## 不変条件 (何が変わってはいけないか)

| ID | 条件 | 今どこにあるか |
|---|---|---|
| I1 | 画面に見えたタイルは、いずれ必ず「画像 or 失敗表示」になる (永久スピナー禁止) | resumeMissingThumbnails の存在理由 |
| I2 | `notSupported` の失敗は勝手に再試行しない。ビューア/プレーヤ表示後にだけ再試行する | `retryUnsupportedThumbnails` |
| I3 | 動画サムネイルは直列で、画像より後。動画再生前にはキャンセルできる | ThumbnailLoader のバッチ規則 + `cancelThumbnailWork` |
| I4 | Pixiv サムネイル URL の陳腐化時は取り直す ([pixiv_connection.md](../pixiv_connection.md)) | provider.fetchThumbnail 内。**本設計の外、変更なし** |
| I5 | 取得したサムネイルは L2 (ディスク) に永続化される | `_loadOne` |
| I6 | まとめ計測ログを出す (性能問題の一次証拠。2026-08-02 の調査で確立) | attach / Batch done ログ |

## 構成

```
GalleryView のタイル ──(1) pool.get(id)──▶ ThumbnailPool (アプリで 1 つ、上限つき LRU)
   │ ヒット: 描く                              ▲ (4) put + 項目別通知
   │ ミス: (2) want(item, 距離)                │
   ▼                                           │
ThumbnailScheduler (アプリで 1 つ) ──(3)──▶ ディスクレーン: L2.get、並列 8
   優先度つきキュー                        ネットレーン: fetchThumbnail → L2.put、並列 5
   ビューポート追従・重複統合・帯外破棄    動画レーン: 直列、画像より後
```

- **(1)(2) 引く側**: タイルは `pool.get` → ミスなら `scheduler.want` を積んで
  プレースホルダ。結果は項目別 `ValueListenable` で届き、そのタイルだけ再描画
- **(3) 応える側**: L2 にあればディスクレーン、なければネットレーン。
  どちらも完了時に (4) プールへ入れて通知。ネット取得は L2 にも書く (I5)
- セッション (`GallerySession`) はアイテム列・ページング・anchor・mark を
  持ち続ける。**サムネイルの所有からは外れる**

## ThumbnailPool

- キー: アイテム id (キャッシュキー `thumb:<id>` と同じ綴り)。
  値: `ThumbnailResult` (エンコード済みバイト or 失敗)
- **上限はバイト数で 32MB** (定数、ログを見て調整)。成功エントリのバイト数を
  数え、超えたら LRU で押し出す。実測用に件数と総バイトを定期ログ
- 失敗エントリはバイト 0 として数える (押し出しは件数上限 2048 で別途)。
  失敗も「答え」なので、貯めないと同じ失敗を描画のたびに取りに行ってしまう
- `removeWhere(predicate)`: `notSupported` の再試行 (I2) は、該当エントリを
  消す → タイルが描かれ直すときに再要求される、で実現する
- 通知: エントリごとの `ValueListenable<ThumbnailResult?>`。プール全体の
  リスナーは持たない (グリッド全面 setState を作らないため)

サムネイルを L1 (`MemoryCache`、10 枚、フル画像と共用) に書くのは**やめる**。
プールがその役割を引き継ぐ。L1 はフル画像専用に戻る。

## ThumbnailScheduler

### 要求と優先度

- `want(request)`: セッション id・アイテム・ビューポートからの距離 (行数) を
  持つ。同じアイテム id の要求は 1 つに統合し、距離は小さい方を採る
- 優先度: **可視 (距離 0) > スクロール方向側の帯 > 反対側の帯**。
  帯の幅は 1 画面ぶん = `galleryCrossAxisCount × ceil(ビューポート高さ ÷
  galleryRowStride(幅))`。回転・リサイズに追従する
- `updateViewport(sessionId, first, last, direction)`: スクロールで呼ぶ。
  キューを並べ直し、**帯から外れた要求は捨てる** (帯に入り直せばタイルの
  描画が再要求する)。先読みはここが帯内の未要求アイテムを want で積む
- `dropSession(sessionId)`: ビューが離れた (detach 相当)。そのセッションの
  キュー内要求を捨てる。**取得中のものは完走させて L2 とプールに入れる**
  (捨てても帯に戻れば再要求されるだけで、完走の方が安い)

### レーン

| レーン | 並列度 | 対象 | 規則 |
|---|---|---|---|
| ディスク | 8 | L2 ヒット | 実測 1 件 18ms。8 並列で可視 15 件 ≈ 40ms |
| ネット | 5 (現行踏襲) | L2 ミス | 完了時 L2 へ書く (I5) |
| 動画 | 1 (現行踏襲) | `isVideo` | 画像レーンが空くまで待つ (I3)。`pauseVideos(sourceKey)` / `resume()` で動画再生と排他 |

失敗はプールに `ThumbnailFailed` として入れる (I1 の「失敗表示になる」側)。
`notSupported` 以外の失敗 (タイムアウト等) の再試行規則は現行踏襲:
自動では再試行せず、pull-to-refresh 等でプールから消えたときに再取得。

### 計測 (I6)

- 要求の波 (キューが空 → 積まれる → また空) ごとに 1 行:
  `wave: 42 wanted = 18 pool + 20 disk + 4 net, 230ms`
- プールの水位を put 256 回ごとに 1 行: `pool: 612 entries, 28.4MB`

## 各シナリオの動き

| シナリオ | 動き |
|---|---|
| 一覧を開く | 可視タイルが要求 → ネット取得 (初回) が優先度順に埋まる。先読み帯が続く |
| スクロール | 見えたタイルが要求 + 帯を追従。通り過ぎた帯外の要求は破棄 |
| タブ切替で戻る | プールに残っていれば**即** (I/O ゼロ)。押し出されていた分だけディスク 8 並列。全 591 件の読み直しはしない |
| ビューア往復 | タブ切替と同じ。`notSupported` はプールから消して再要求 (I2) |
| キャッシュクリア | タイルが描かれるたび要求し直すだけ。帳簿が無いので食い違いも無い (I1) |
| メモリ | 常に 32MB + 失敗エントリ以内。捨てる判断は LRU に一任 |

## 消えるもの / 残るもの

**消える**: `GallerySession.detach/attach` の全捨て・全読み直し、
`_thumbnailResults`、`_resultIds`、配布水位 (`_loadedCount`)、`needsBatchFor`
とタイル側のバッチ起動、`resumeMissingThumbnails`、`retryInterrupted`。

**残る**: ページング (`loadNextPage`、サムネイルと直交)、`ScrollAnchor`、
`ViewerMark`、失敗の型 (`ThumbnailResult` sealed class)、
`VideoThumbnailService`、`SmbProxyServer`、I4 の取り直し。

## 進め方 (各段階でテスト緑 + 実機確認 + commit)

| 段階 | 内容 | 完了条件 |
|---|---|---|
| 0 | **特性テスト**: I1〜I3 を widget テストで固定 (見えたタイルが埋まる / 失敗表示 / notSupported の再試行タイミング / 動画直列)。基準ログは 2026-08-02 取得済み | 現行コードで緑 |
| 1 | **ThumbnailPool 導入**: プールを作り、既存ローダーの結果をプールにも書く。グリッドの読み口を `thumbnailFor` → プールに差し替え (セッションのマップは併存) | 挙動不変で緑 |
| 2 | **スケジューラ + プル化**: タイル描画駆動の want、`updateViewport`、attach/detach を dropSession だけに。旧経路 (帳簿・水位・全読み直し) を**削除** | 実機で「タブから戻る」の可視タイルが 0.5 秒以内。キャッシュクリア → スクロールで埋まる |
| 3 | **通知の粒度**: 項目別 ValueListenable に完全移行、サムネイル起因のグリッド全面 setState を削除。サムネイルの L1 書き込み停止 | 実機で描画のカクつきが増えていない |
| 4 | **文書**: thumbnail_architecture.md を書き直し、ADR 011 を Accepted に。cq-metrics + trend 追記 | — |

段階 2 が本体。0/1 は安全網で、2 の途中で壊れたときに「どこまでは正しいか」を
機械が答えられるようにする。

## 残る検討

- プール上限 32MB の妥当性 (水位ログで判断。サムネイルは長辺 600px /
  400KB 上限なので最悪 80 件、Pixiv の実測は数十 KB で数百件の見込み)
- ディスクレーン並列 8 の妥当性 (実測 18ms/件が並列でどうスケールするか)
- `DiskCache.get` の 18ms/件そのものが妥当か (小ファイル 1 読みとしては
  遅め。LRU タッチの `_scheduleFlush` が疑い筋だが、並列化で足りるなら掘らない)
