# 仮想化ギャラリー — 設計 (初稿・すり合わせ用)

> Status: Draft。全体像とデータモデルの骨子。未決事項は「## 未決事項」に集約。
> 確定したら該当箇所を更新し、設計判断は ADR (007 予定) に切り出す。

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

- **タブの識別子** = このソース URI。同じ URI のタブは 1 つ (重複開防止)。
- **アイテムの identity / キャッシュキー** = アイテム URI (`thumb:<uri>` / `full:<uri>`)。
  現行の `thumb:<id>` 命名をこれに寄せる (id は既に URI 化しやすい)。

### 3. タブモデル (R2, R7)

```
class GalleryTab {
  final Uri sourceUri;              // 識別子 (R5)
  final PagedItems items;          // 仮想列 (R1, R3)
  final List<ImageSource> loaded;  // 取得済みアイテム (窓の裏の配列)
  Object? nextCursor;              // 次ページ (R3)
  double scrollOffset;             // 復元 (R2)
  final ThumbnailLoader thumbs;    // 共通エンジン (R4)
}
```

- タブ集合を 1 箇所 (仮称 `GalleryTabController`) が保持し、行き来で state を保存。
- 非表示タブは `ThumbnailLoader.cancel()` + デコード済み画像解放 (R7)。復帰時に
  キャッシュから再表示 (既存 activate/deactivate パターンの一般化)。

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

## 未決事項 (すり合わせたい点)

1. **責務分界**: paging を「タブ (GalleryTabController)」に置くか、`PagedItems` に持たせて
   `ThumbnailLoader` と協調させるか。案では paging=タブ、thumbs=ThumbnailLoader で分離。
2. **`ImageSourceProvider.listImages(path)` の扱い**: cursor ベース `loadPage` へ移行するか、
   薄いアダプタで両立させるか (既存呼び出し側の影響範囲)。
3. **タブの上限とメモリ方針** (R7): 何タブまで保持、非表示タブの解放粒度 (loaded 配列も捨てるか、
   デコード画像だけか)。
4. **URI 体系の確定**: 上記スキームで過不足ないか (ZIP 内・PDF ページ・複数ページ Pixiv の
   `_p{i}` をどう URI 化するか)。
5. **非画像アイテム**: SMB のディレクトリ/動画をどう仮想列に混ぜるか (現行はメタデータ分岐)。
6. **移行の段階**: 一気に全ソースを載せ替えず、まず 1 ソース (SMB or Pixiv) で仮想リストを
   実証 → タブ統合 → 残りを移行、の順を想定。挙動変化が大きいので各段で characterization +
   実機 verify。

## 進め方 (案)

spec-dev 軽量。要件が新規なので本 design.md で要件・データモデルを固め、確定分を
ADR 007 に切り出す。実装は段階 (未決 6) に分け、各段で回帰テスト + 実機確認。
既存の gallery_unification の成果 (2a-2c) はこのアーキの土台として活きる。
