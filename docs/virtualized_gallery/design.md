# 仮想化ギャラリー — 設計

> Status: データモデルと所有方針は確定 ([ADR 007](../adr/007-virtualized-gallery.md))。
> タブ identity とタブ内ナビ履歴は [ADR 008](../adr/008-tab-identity-and-history.md) で改訂。
> 実装は段階化 (「## 進め方」)。細部の残論点は「## 残る検討」。

全ソース (SMB ディレクトリ・Pixiv 検索/ユーザー/ブックマーク・お気に入り・DL 済み) を
**同一の仮想アイテム列**として扱い、複数タブに並べて行き来でき、サムネイル取得を
**単一の共通エンジン**に集約するアーキテクチャ。既存の 2 画面重複除去
([gallery_unification](../gallery_unification/design.md)) の一段上の構想で、
そこで汎用化した `ThumbnailLoader` / `GalleryGrid` / `GalleryKeyboardScrollable` を土台にする。

## 背景・目的

現状は SMB 画面と Pixiv 画面が別実装で、次の非対称がある。

- タブは Pixiv 画面の中だけ (トップ/ブックマーク/お気に入り)。SMB は画面ごと。
- Pixiv はタブ別・追記ページネーション。SMB は 1 ディレクトリ = 固定リスト。
- サムネイル取得は SMB が `ThumbnailLoader`、Pixiv が独自 (直列だった。暫定並列化済み)。

やりたいこと: **選んだソースがタブとして並列に並び、行ったり来たりできる**。
SMB の複数フォルダ・Pixiv 検索結果・お気に入りが対等に共存する。そのために
「ソースの種類に依存しない仮想アイテム列 + スクロール駆動のバッチ取得」を共通基盤にする。

## 要件 (新規)

| ID | 要件 |
|---|---|
| R1 | 任意のソース (SMB dir / Pixiv search・user・bookmarks・top / favorites / DL 済み) を**同一の仮想アイテム列**として扱える |
| R2 | 複数タブを**並列に保持**し行き来できる。各タブはスクロール位置・読み込み位置・サムネイル状態を保持 |
| R3 | スクロール末尾接近で**次ページを遅延取得**。総数不定 (Pixiv 検索等) を許容 |
| R4 | サムネイル取得は全ソース共通の `ThumbnailLoader` (並列バッチ + L1/L2 キャッシュ + cancel/retry) |
| R5 | アイテム identity・キャッシュキー・タブ識別子・復元キーを **URI で統一** |
| R6 | 表示層は既存 `GalleryGrid` / `GalleryKeyboardScrollable` を再利用 |
| R7 | メモリ: **可視窓 + 近傍のみ**デコード済み画像を保持。非表示タブ・遠方アイテムは解放 (仮想化) |

非目標 (今回): 検索 UI の刷新、DL 済みブラウズ UI の新設、動画プレーヤ改善。
これらは仮想リストに載る「ソースの一種」として後付けできればよい。

## 中核データモデル

### 1. 仮想アイテム列 (`PagedItems` / 仮称)

ソースを「ページ単位で `ImageSource` を遅延供給する列」として抽象化する。

```
abstract class PagedItems {
  /// 次のページを取得。cursor は不透明 (offset/page番号/URLをソースが解釈)。
  /// 返り値の nextCursor が null なら末尾。total は分かれば返す (不明可)。
  Future<PageResult> loadPage(Object? cursor);
}
class PageResult { List<ImageSource> items; Object? nextCursor; int? total; }
```

- **SMB ディレクトリ**: 初回 1 ページで全件確定 (`nextCursor == null`)。
- **Pixiv 検索/ユーザー/ブックマーク**: ページごとにサーバー取得。`nextCursor` で継続。総数不明可。
- **お気に入り / DL 済み**: ローカル列挙を 1 ページ (or チャンク) で供給。
- 現状の `ImageSourceProvider.listImages({path})` + `PixivSource._nextOffset` を、この
  cursor ベース API に寄せる (paging 状態を呼び出し側=タブが持つ。プロバイダは無状態化)。

### 2. URI による identity 統一 (R5)

タブ・アイテム・キャッシュキーを URI で表す。既存の sourceKey (`pixiv:default`,
`smb:<id>`) と Pixiv パス (`/search?word=`, `/user/123`, `/bookmarks`, `/top`) を統合:

```
smb://<serverId>/<path>                      (ディレクトリ or ファイル)
pixiv://search?word=...&order=date_d
pixiv://user/123
pixiv://bookmarks
pixiv://top
fav://                                        (お気に入り一覧)
dl://                                         (DL 済み一覧)
```

- **URI は「場所」の表現**。タブの識別子ではない ([ADR 008](../adr/008-tab-identity-and-history.md))。
  タブ identity はタブ固有 ID で、同じ URI のタブを複数開いてよい。
- **アイテムの identity / キャッシュキー** = アイテム URI (`thumb:<uri>` / `full:<uri>`)。
  現行の `thumb:<id>` 命名をこれに寄せる (id は既に URI 化しやすい)。

### 3. タブモデル (R2, R7) — ブラウザのタブ ([ADR 008](../adr/008-tab-identity-and-history.md))

タブは「入れ物」で、その中に**閲覧場所の履歴スタック**が入る。identity は入れ物側
(タブ固有 ID)、URI は履歴の要素が持つ。

```
class GalleryTab {                      // ブラウザのタブ
  final String id;                      // identity (不変、URI ではない)
  final List<GallerySession> history;   // 閲覧場所の履歴
  int index;                            // 現在位置 (戻る/進む)
  GallerySession get current => history[index];
}

class GallerySession {                  // 履歴の 1 要素 = 1 閲覧場所
  final Uri sourceUri;                  // どこを見ているか (R5)
  final List<ImageSource> loaded;       // 取得済みアイテム (窓の裏の配列)
  Object? nextCursor;                   // 次ページ (R3)
  double scrollOffset;                  // 復元 (R2)
  final ThumbnailLoader thumbs;         // 共通エンジン (R4)
}
```

`GallerySession` が ADR 007 決定 1 の「閲覧セッションを所有するタブ」の実体で、
フェーズ 1/2A で `GalleryTab` として実装済み。ADR 008 で名前を新しい器に譲る。

- タブ集合を 1 箇所 (仮称 `GalleryTabController`) が保持し、行き来で state を保存。
- **ナビはタブ内で完結**: ディレクトリ移動・検索・作者遷移は `Navigator.push` ではなく
  `tab.navigate(uri)` で履歴に積む。戻る操作は履歴を 1 つ戻し、履歴の先頭で戻ると
  ギャラリー画面自体を pop する。履歴の途中から navigate すると先の履歴は破棄。
- 戻ってもセッションが生きているので**再取得しない** (アイテム列・スクロール位置が復元)。
- デコード済み画像 (L1) を保持するのは**アクティブタブの現在セッションだけ** (R7)。
  同一タブの履歴内の他セッション・非アクティブタブは `ThumbnailLoader.cancel()` +
  L1 解放。復帰時に L2 から再表示 (既存 activate/deactivate パターンの一般化)。

#### データ所有の整理 (現状 → 目標)

閲覧セッションの状態が今はソース/画面/タブに不揃いに散らばっている。これを
`GallerySession` に集約し、ソースを無状態化する。★ = 不揃いの元凶。

| データ | 現在 Pixiv | 現在 SMB | 目標オーナー |
|---|---|---|---|
| アイテム列 (取得済み) | `_TabState.images` | `_items` / `_imageFiles` | `GallerySession.loaded` |
| ページカーソル (次ページ) | ★`PixivSource._nextOffset` (ソース内) | なし (有限) | `GallerySession.nextCursor` |
| サムネイル状態 | `_TabState.thumbnails` (`Uint8List`) | `_thumbnailData` (`ThumbnailResult`) | `GallerySession` (`ThumbnailResult` 統一) |
| サムネ取得進捗 | 画面に散在 (`loadGeneration` 等) | ★`ThumbnailLoader` 内部 | `GallerySession.thumbLoader` (セッションごと) |
| スクロール位置 | `_TabState.scrollOffset` | 保存なし | `GallerySession.scrollOffset` |
| ソース識別子/検索条件 | `initialUserPath` + `_searchMode`/`_searchOrder` | `initialPath` | `GallerySession.sourceUri` (条件も内包) |
| ナビ履歴 | ★Navigator スタック (画面 push) | ★Navigator スタック (画面 push) | `GalleryTab.history` (タブ内) |
| タブ集合 | `_tabStates` (固定3タブ、画面内) | なし (別画面) | `GalleryTabController` (ソース横断) |
| ソース本体 (接続/認証/取得) | `PixivSource` + app 共有 `PixivApiClient` | `SmbSource` (サーバ単位、registry) | プロバイダのまま。**カーソルを外出しし無状態化**。接続/ZIP/PDF/動画キャッシュは resource として保持 |
| L1/L2/L3 キャッシュ | app `CacheManager` | 同左 | 変えず (キーをアイテム URI に統一) |

動かすのは「その閲覧セッション固有の状態」だけ。要は ①ページカーソルをソースから
セッションへ外出し ②サムネ取得をセッションごとの `ThumbnailLoader` に統一 ③残りを
`GallerySession` に同じ形で集約 ④ナビ履歴を Navigator からタブへ移す、の 4 つ。

### 4. スクロール単一トリガ (R3, R4) — SMB/Pixiv の差を吸収する要

可視窓が動いたとき、1 経路で 2 つを駆動する:

1. **ページ供給**: 窓末尾が `loaded` 末尾に近く `nextCursor != null` なら `loadPage(nextCursor)`
   を呼び `loaded` に追記 (R3)。SMB は初回で `nextCursor == null` になるので以後発火しない。
2. **サムネイル dispatch**: 窓内の未取得アイテムを `ThumbnailLoader` に投げる (R4)。

これで「固定リスト + スクロールバッチ (SMB)」と「追記ページネーション (Pixiv)」が
**同じ 1 経路**になる。現在 `gallery_screen` の `_onScroll`/`_loadMore` と
`smb_gallery_screen` の `needsBatch`/`loadNextBatch` に割れているものの統合。

### 5. `ThumbnailLoader` の追記対応

現 `setItems()` は全リセット前提 (固定リスト向け)。追記ページに対応するため
`addItems(more)` 相当 (既存の `_resultIds`/`_loadedCount` を保ったまま列を伸ばす) を
足す。これが [gallery_unification](../gallery_unification/design.md) の旧 Step 2d で
見えた「append の食い違い」の解消策。

## 既存部品の位置づけ (再利用)

| 部品 | 役割 (このアーキ内) | 状態 |
|---|---|---|
| `ThumbnailLoader` | 全ソース共通のサムネイルバッチ実行器 | 2a-2c で `ImageSourceProvider` 汎用化済み。`addItems` 追加が必要 |
| `GalleryGrid` | 窓の描画 + スクロールトリガ | 済 (tileBuilder は各ソース) |
| `GalleryKeyboardScrollable` | 入力・スクロール・pop | 済 |
| `ImageSourceProvider` | ソースごとの取得 (fetchThumbnail 等) | 済。`listImages` を paged API に寄せる検討 |
| `CacheManager` | L1/L2/L3。キーを URI 化 | キー命名の見直しのみ |
| `SourceRegistry` | URI → プロバイダ解決 | URI 体系に合わせて拡張 |

## 決定事項 ([ADR 007](../adr/007-virtualized-gallery.md) / [ADR 008](../adr/008-tab-identity-and-history.md))

1. **責務分界**: paging=閲覧セッション (`GallerySession` が `loaded`/`nextCursor`/
   `scrollOffset`/`thumbLoader` を所有)、ソースは無状態の `loadPage(cursor)`。
   上記「データ所有の整理」の通り。
2. **`listImages` 移行**: `ImageSourceProvider` に `loadPage(cursor)` を追加。有限ソースは
   既定実装が `listImages` を 1 ページとして包む → 段階移行 (既存呼び出しを一斉に壊さない)。
3. **タブのメモリ**: 開いているタブの `loaded` は保持、非表示タブのデコード済みサムネ (L1) は
   解放し復帰時に L2 から再表示。タブ数のハード上限は当面なし + デコード画像を LRU 排出。
4. **URI 体系**: `smb://<serverId>/<path>` / `pixiv://search?...` / `pixiv://user/123` /
   `pixiv://bookmarks` / `pixiv://top` / `fav://` / `dl://`。コンテナ内は fragment
   (`…#entry`, `…#page=3`, Pixiv 複数ページ `…#p2`)。キャッシュキー `thumb:<uri>` / `full:<uri>`。
5. **タブ identity と履歴** (ADR 008): identity はタブ固有 ID。URI は履歴の要素が持つ
   「今いる場所」。同じ URI のタブを複数開いてよい (重複開防止はしない)。ナビはタブ内で
   完結し、履歴の先頭で戻ると画面を pop。L1 保持はアクティブタブの現在セッションのみ。

## 残る検討 (実装時に確定)

- **非画像アイテム**: SMB のディレクトリ/動画は `loaded` に混在する `ImageSource` (メタデータ
  フラグ) のまま。tileBuilder が描画を、タップ時にディレクトリならその dir URI へ
  `tab.navigate` (同一タブの履歴に積む)。現行のメタデータ分岐を踏襲する方向。
- `GalleryTabController` の UI (タブバー・並び・閉じる操作・複製) の具体。
- 「進む」操作をどの入力に割り当てるか (戻るは ESC / Backspace / 戻るボタン / 横スワイプ)。
- `loadPage` の cursor 型 (不透明 Object) を各ソースがどう解釈するか (SMB=null 一発、
  Pixiv=offset/page)。

## 進め方 (段階)

挙動変化が大きいので段階化し、各段で characterization + 実機 verify。既存の
gallery_unification 成果 (`ThumbnailLoader` 汎用化・`GalleryGrid`・`GalleryKeyboardScrollable`)
が土台。

1. **フェーズ 1** (完了): `PagedItems` / `loadPage` 抽象と `GalleryTab` (= 後の
   `GallerySession`) を導入し、SMB 画面で「仮想列 + スクロール単一トリガ + セッション
   ごと ThumbnailLoader」を実証。`ThumbnailLoader.addItems` 追加もここ。
2. **フェーズ 2A** (完了): Pixiv 画面を単一 navigable ビュー + 同モデル化。SMB と
   読み込み経路を共通化。
3. **フェーズ 2B**: ブラウザ的タブ ([ADR 008](../adr/008-tab-identity-and-history.md))。
   見た目を変えずにセッションの独立性を上げてから、最後にタブ集合へ置き換える:

   | | 内容 | 挙動 |
   |---|---|---|
   | 2B-1 | `GalleryTab` → `GallerySession` リネーム | 不変 |
   | 2B-2 | `_thumbnailData` を `GallerySession` へ | 不変 |
   | 2B-3 | `_thumbIndex` を `GallerySession` へ (`loadNextPage` 内で更新) | 不変 |
   | 2B-4 | activate/deactivate の L1 解放・再読込を `GallerySession.attach()/detach()` へ | 不変 |
   | 2B-5 | `scrollOffset` を実際に保存・復元 (現状は未使用フィールド) | 不変 |
   | 2B-6 | `GallerySession.fromUri(uri, registry)` ファクトリ (URI 駆動生成) | 不変 |
   | 2B-7 | 両画面の残り glue を共通 `GalleryView` ウィジェットへ (tileBuilder / AppBar は注入) | 不変 |
   | 2B-8 | `GalleryTab` (id + history + index) を導入、画面は `tab.current` を見る | 不変 (履歴長 1) |
   | 2B-9 | 画面内ナビを `Navigator.push` → `tab.navigate(uri)`。戻るは履歴 pop、先頭で画面 pop | **変化** |
   | 2B-10 | `GalleryTabController` + タブバー UI。複製・リンクからのタブ生成 | **変化** |

   2B-7 を 2B-9 より先に置くのは、ナビモデルの変更を 1 箇所で済ませるため。
4. **フェーズ 3**: 残りソース (お気に入り・DL 済み等) を仮想列に移行。URI/キャッシュキー統一。
