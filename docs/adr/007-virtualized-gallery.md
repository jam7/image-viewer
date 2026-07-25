# 007: ギャラリーを仮想化ページリストモデルに統一する

## Status

Accepted (決定 4 のタブ identity は [ADR 008](008-tab-identity-and-history.md) で改訂)

## Context

全ソース (SMB ディレクトリ・Pixiv 検索/ユーザー/ブックマーク/トップ・お気に入り・DL 済み)
を対等なタブとして並列に並べ、行き来できるようにしたい。現状は非対称:

- タブは Pixiv 画面の中だけ。SMB は Navigator スタックの別画面。
- **ページネーションのカーソルが Pixiv では `PixivSource._nextOffset` とソース内**にあり、
  ソースがタブごとに new される「ファイルディスクリプタ」的な状態持ちになっている。
  一方 SMB はページネーションが無く、バッチ取得状態は `ThumbnailLoader` に集約されている。
- サムネイル取得は SMB が `ThumbnailLoader`、Pixiv が画面内に散在 (P1 で並列化はしたが別実装)。

閲覧セッションの状態 (アイテム列・カーソル・スクロール位置・サムネイル状態) が
ソース/画面/タブに不揃いに散らばっているのが、共通化を阻む根本。設計の詳細は
[docs/virtualized_gallery/design.md](../virtualized_gallery/design.md)。

## Alternatives

### A. 既存 2 画面の重複除去だけ ([gallery_unification](../gallery_unification/design.md))

- 共有ウィジェット抽出は済んだが、**ソース横断のタブ**も**統一ページネーション**も得られない。

### B. ページネーションをソースに持たせて汎用化 (現 Pixiv 方式の一般化)

- ソースが状態持ちのままになり、再利用・テストがしにくい。SMB はページネーションが
  無いのに状態を持たされる。不揃いの元凶を温存する。

### C. 仮想化ページリストモデル (閲覧セッションはタブ所有、ソースは無状態)

- ソースを「ページ単位で遅延供給する無状態の列」に、閲覧セッションを「タブ」に集約。

## Decision

**C を採用する。** 閲覧セッション固有の状態はすべて `GalleryTab` が所有し、ソースは
無状態のページ取得器にする。要点:

1. **`GalleryTab` が閲覧セッションを所有**: `loaded` (取得済みアイテム列)、`nextCursor`、
   `scrollOffset`、タブごとの `ThumbnailLoader`、`sourceUri`。タブ集合は
   `GalleryTabController` が保持し、ソース横断で並列・行き来できる。
2. **ソースは無状態の `PagedItems`**: `loadPage(cursor) -> (items, nextCursor?, total?)`。
   有限ソース (SMB dir・お気に入り) は 1 ページで `nextCursor == null`。
   `ImageSourceProvider` に `loadPage` を追加し、既定実装が既存 `listImages` を 1 ページとして
   包む (段階移行)。**ページカーソルをソースからタブへ外出しする**のが本 ADR の肝。
3. **スクロール単一トリガ**が可視窓に対し ①末尾接近かつ `nextCursor != null` なら次ページ取得
   ②窓内の未取得サムネを `ThumbnailLoader` に dispatch、を両方駆動。これで SMB の
   固定リストと Pixiv の追記ページネーションが同一経路になる。`ThumbnailLoader` に
   追記用 `addItems` を足す。
4. **URI で identity 統一**: タブ識別子・アイテム identity・キャッシュキーを URI に
   (→ タブ識別子の部分は [ADR 008](008-tab-identity-and-history.md) でタブ固有 ID に改訂。
   アイテム identity とキャッシュキーは本決定のまま)
   (`smb://`, `pixiv://search?...`, `pixiv://user/123`, `fav://`, `dl://`)。コンテナ内アイテムは
   fragment で名前空間化 (ZIP `…#entry`、PDF `…#page=3`、Pixiv 複数ページ `…#p2`)。
   キャッシュキーは `thumb:<uri>` / `full:<uri>`。
5. **メモリ**: 開いているタブの `loaded` (軽いメタ列) は保持。非表示タブのデコード済み
   サムネ (L1) は解放し、復帰時に L2 から再表示 (現 activate/deactivate の一般化)。

接続・認証・ZIP/PDF/動画キャッシュは "resource" としてプロバイダに残す (動かすのは
セッション固有状態だけ)。

## Consequences

- **Good**: ソース横断の並列タブが可能に。サムネイルエンジンが 1 本化 (ADR 006 の汎用化を活用)。
- **Good**: ソースが無状態化し再利用・テストが容易。キャッシュキーが URI で一意化。
- **Good**: `GalleryGrid` / `GalleryKeyboardScrollable` (gallery_unification 成果) をそのまま土台にできる。
- **Bad/リスク**: 挙動変化の大きい移行。段階化 + 実機 verify が必須。`loadPage` 追加は全
  プロバイダに波及する (既定実装で緩和)。
- **Note**: gallery_unification の旧 Step 2d (Pixiv が ThumbnailLoader を bolt-on 採用) は
  本 ADR に吸収され取り下げ。当座の P1 は Pixiv 側の行単位並列化で解消済み。
