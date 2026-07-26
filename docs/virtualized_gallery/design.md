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

形は全スキーム共通で **`<scheme>://<instanceId>/<path>`**。authority が
「ソースのどのインスタンスか」、path が「その中のどこか」を表す。

```
smb://<configId>/<dir>/<subdir>               (登録済みサーバー 1 台の中のディレクトリ)
pixiv://default/top
pixiv://default/bookmarks
pixiv://default/favorites
pixiv://default/user/123
pixiv://default/search?word=...&s_mode=...&order=date_d
fav://<instance>/                             (お気に入り一覧、フェーズ 3)
dl://<instance>/                              (DL 済み一覧、フェーズ 3)
```

- **URI は「場所」の表現**。タブの識別子ではない ([ADR 008](../adr/008-tab-identity-and-history.md))。
  タブ identity はタブ固有 ID で、同じ URI のタブを複数開いてよい。
- **アイテムの identity / キャッシュキー** = アイテム URI (`thumb:<uri>` / `full:<uri>`)。
  現行の `thumb:<id>` 命名をこれに寄せる (id は既に URI 化しやすい)。

#### 構文の詳細 (2B-6 で実測して確定、ADR 007 の記載から 2 点変更)

実装は `lib/screens/gallery/gallery_uri.dart`。往復テストは
`test/screens/gallery/gallery_uri_test.dart`。

- **authority には常に「インスタンス ID」を入れる**。ADR 007 は `pixiv://top` /
  `pixiv://user/123` と書いていたが、これは `top` や `user` を**ホスト位置**に置く形で、
  SMB の `smb://<configId>/...` (ホスト = サーバー) と意味が揃わない。Pixiv は
  インスタンスが 1 つしか無いだけで authority が無いわけではないので、`default` を
  明示して `pixiv://default/top` とする。この結果:
  - **`sourceKey` の取り出しが全スキーム共通で `'${uri.scheme}:${uri.host}'`** になり、
    registry の既存キー (`smb:<configId>` / `pixiv:default`) とそのまま一致する。
    2B-10 で `registry.resolve()` に渡すときにスキームごとの分岐が要らない
  - `uri.path` が純粋に「場所」だけになる (host と path を組み直す必要がない)
  - フェーズ 3 の `fav://` / `dl://` も同じ形に従う
  - **`default` は「消してよい飾り」ではなく「今は値が 1 つなだけ」**。認証を伴う
    サービス (DMM 等) は Pixiv と同じ単一インスタンス型になるので同じ形で載る。
    将来アカウントを使い分けたくなったら `pixiv://<accountId>/...` が
    `pixiv://default/...` の隣に並ぶだけで、URI 形式もキー導出も変えずに済む
- **SMB パスは区切りを `\` ↔ `/` に対応付けて URI の path *segments* に載せる**。
  実際の SMB パスは `books\作品集第2巻.pdf` のようにバックスラッシュ区切りで、
  空白・`#`・`%`・非 ASCII を含む。`Uri` の path 成分にそのまま入れるとバックスラッシュが
  黙ってスラッシュに変換されて区別が付かなくなるが、SMB は Windows と同じくファイル名に
  `/` を使えないので、区切りとして対応付ければ可逆になる。**デコードは
  `Uri.pathSegments` を使うこと** (`Uri.path` はパーセントエンコードされたまま返す)。
  先頭の区切りは落ちるが、dart_smb2 の `_normalizePath` が同じことをするので影響なし

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
  ScrollAnchor? anchor;                 // 表示位置 (R2、下記)
  final ThumbnailLoader thumbs;         // 共通エンジン (R4)
}
```

`GallerySession` が ADR 007 決定 1 の「閲覧セッションを所有するタブ」の実体で、
フェーズ 1/2A で `GalleryTab` として実装済み。ADR 008 で名前を新しい器に譲る。

- タブ集合を 1 箇所 (仮称 `GalleryTabController`) が保持し、行き来で state を保存。
- **ナビはタブ内で完結**: ディレクトリ移動・検索・作者遷移は `Navigator.push` ではなく
  `tab.navigate(uri)` で履歴に積む。戻る操作は履歴を 1 つ戻し、**履歴の先頭では
  何もしない** (システムのジェスチャだけは OS に渡す)。タブを閉じるのは `x` のみで、
  戻るは破壊しない ([ADR 009 追記](../adr/009-navigation-toolbar.md))。
  履歴の途中から navigate すると先の履歴は破棄。
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
| スクロール位置 | `_TabState.scrollOffset` (px) | 保存なし | `GallerySession.anchor` (アイテム基準、下記 4) |
| ソース識別子/検索条件 | `initialUserPath` + `_searchMode`/`_searchOrder` | `initialPath` | `GallerySession.sourceUri` (条件も内包) |
| ナビ履歴 | ★Navigator スタック (画面 push) | ★Navigator スタック (画面 push) | `GalleryTab.history` (タブ内) |
| タブ集合 | `_tabStates` (固定3タブ、画面内) | なし (別画面) | `GalleryTabController` (ソース横断) |
| ソース本体 (接続/認証/取得) | `PixivSource` + app 共有 `PixivApiClient` | `SmbSource` (サーバ単位、registry) | プロバイダのまま。**カーソルを外出しし無状態化**。接続/ZIP/PDF/動画キャッシュは resource として保持 |
| L1/L2/L3 キャッシュ | app `CacheManager` | 同左 | 変えず (キーをアイテム URI に統一) |

動かすのは「その閲覧セッション固有の状態」だけ。要は ①ページカーソルをソースから
セッションへ外出し ②サムネ取得をセッションごとの `ThumbnailLoader` に統一 ③残りを
`GallerySession` に同じ形で集約 ④ナビ履歴を Navigator からタブへ移す、の 4 つ。

### 4. 表示位置はピクセルでなくアイテムのアンカーで持つ (R2)

表示位置をスクロールのピクセル値で持つと、画面の縦横が変わったときに表示中の項目が
大きくズレる。`galleryCrossAxisCount = 5` 固定・`childAspectRatio` 既定 (正方形タイル)
なので、**行の高さが画面幅に比例する**ため:

| | 画面幅 | 行の高さ | offset 5000px の位置 |
|---|---|---|---|
| 縦 | 820 | 163.2 | 30.6 行目 ≒ 153 番目 |
| 横 | 1180 | 235.2 | 21.3 行目 ≒ 106 番目 |

そこで位置は**左上に見えているアイテム**を基準に持つ。

```
class ScrollAnchor {
  final String itemId;      // 左上に見えているアイテム (順番ではなく identity)
  final double rowFraction; // その行の上端からのズレ / 行高
}

復元 = (indexOf(itemId) ~/ 現在の列数) * 現在の行高 + rowFraction * 現在の行高
```

- **順番 (index) ではなく id** を持つ。Pixiv 画面には表示専用の `>N` ページ数フィルタが
  あり、表示列と `loaded` が一致しない。フィルタやソートを変えた状態で復元すると
  「153 番目」は別アイテムを指す。id なら復元時に現在の列から引き直せ、見つからなければ
  先頭にフォールバックできる。索引は `GallerySession` が持つ id→index マップを流用する。
- **`rowFraction` も持つ**。行 index だけだと復元時に必ず行頭に吸着し、ビューアから
  戻っただけのときに軽く飛ぶ。
- 「現在の列数」で割る形にしておくと、列数を画面幅に応じて可変にしたときもそのまま効く。

直すべきケースは 2 つあり、表現 (アンカー) は共通だが機構が違う:

- **(a) 回転・リサイズ中の維持**: ウィジェットは同じまま viewport だけ変わる。metrics
  変更の前後でアンカーを退避・再適用するフックが要る。**現に起きている不具合はこれ**。
- **(b) タブ/履歴切り替えでの復元**: ウィジェットが作り直される。セッションのアンカーから
  復元する。2B-8 以降で観測できるようになる。

### 5. スクロール単一トリガ (R3, R4) — SMB/Pixiv の差を吸収する要

可視窓が動いたとき、1 経路で 2 つを駆動する:

1. **ページ供給**: 窓末尾が `loaded` 末尾に近く `nextCursor != null` なら `loadPage(nextCursor)`
   を呼び `loaded` に追記 (R3)。SMB は初回で `nextCursor == null` になるので以後発火しない。
2. **サムネイル dispatch**: 窓内の未取得アイテムを `ThumbnailLoader` に投げる (R4)。

これで「固定リスト + スクロールバッチ (SMB)」と「追記ページネーション (Pixiv)」が
**同じ 1 経路**になる。現在 `gallery_screen` の `_onScroll`/`_loadMore` と
`smb_gallery_screen` の `needsBatch`/`loadNextBatch` に割れているものの統合。

### 6. `ThumbnailLoader` の追記対応

現 `setItems()` は全リセット前提 (固定リスト向け)。追記ページに対応するため
`addItems(more)` 相当 (既存の `_resultIds`/`_loadedCount` を保ったまま列を伸ばす) を
足す。これが [gallery_unification](../gallery_unification/design.md) の旧 Step 2d で
見えた「append の食い違い」の解消策。

### 7. ナビゲーションツールバー ([ADR 009](../adr/009-navigation-toolbar.md))

Android 15 で戻るボタンが消え、画面端が OS の predictive back に取られたため、
戻る・進む・履歴はジェスチャではなく**画面上の明示 UI** にする (理由は ADR 009)。
ヘッダーはタブストリップ + ツールバーの 2 段構成:

戻る/進むは履歴を歩くだけで、タブを閉じない。閉じるのはタブの `x` のみ
([ADR 009 追記](../adr/009-navigation-toolbar.md))。

```
通常:      [タブ][タブ]… [+]
           ←  →  [ ◎ 佐藤さんの作品            [3+] ]  ☰
検索編集:  ←  →  [ かわいい猫  完全▾ 新着▾  ⿃      ]  ☰
```

#### 場所の窓 (アドレスバー兼検索窓)

Chrome と同じ「表示モードと編集モードの分離」で、検索とアドレスバーの
切り替え操作そのものを無くす:

- **表示モード**: 今いる場所のタイトル (作者名、SMB のパス等) を表示。読み取り専用
- **タップで編集モード**: **その場所で編集したいもの**が全選択される。
  何を出すかはソースが決める (`editable(uri)`):
  - **検索なら語だけ** (`書名 (副題)` に直せる)。クエリ文字列から語を拾い出す
    作業をさせない
  - **それ以外は空**。ヒント文言だけが出る

  空にしたのは、**アドレスをメニューに移した結果**として不要になったから。
  当初は「タップすると URI が全選択される = 専用のコピー機能を作らずに済む」
  という設計で、窓が URI を**見せる**理由はそこにあった。持ち出しが ☰ に移った
  今、窓に残る用は**持ち込み**だけで、その実態は「コピーした URI を貼る」か
  「pixiv.net の URL を貼る」。**URI を手で打つ・手で直す経路は現実に存在しない**。
  空にすると `%E3%81%82` を見せずに済み、消してから打つ手間も無くなり、
  「URI を手で編集して壊す」という失敗の種類そのものが消える
- 打ち始めれば全選択が消えて入力になる。**入力内容が操作を決める**:
  - 既知のスキーム (`pixiv://` `smb://` `fav://` `home://`) で始まる →
    その場所へ移動 (今のタブの履歴に積む)。`GalleryTabOpener.session` が既にある
  - それ以外のテキスト → 今のソースでの検索 (Pixiv のみ。SMB 等は当面無効)
  - 壊れた URI・未知のスキームは**黙って検索扱いに落とす**。`smb://` と打ちかけて
    Enter しても検索になるだけ、という安全側。エラーダイアログは出さない
  - **構文が正しくても「そこには居られない」URI も同じく検索に落とす**
    (`knows(uri)`)。`pixiv://default/usr/12345` は parse できてしまうが、
    provider に渡すと壊れる。形の判定を dialect に置くことで、provider が
    ありえないアドレスから身を守る必要が無くなる
  - **空のまま確定したら何もしない**。窓は大半の場所で空から始まるので、
    これが編集をやめる普通の経路になる (語の無い検索は場所ではない)
- ESC / フォーカス喪失で表示モードに戻る
- **アドレスの持ち出しは ☰ の「アドレスをコピー」**。窓のタップに兼ねさせない。
  「今いる場所を編集する」と「アドレスを持ち出す」は別の用事で、頻度も違う
  (語の編集は日常、持ち出しは時々)。窓が出すのは編集したいものなので、
  検索タブでは語であってアドレスではない。コピーするのは**生の URI** —
  貼った先で必ず同じ場所に戻るのはこちらだけ

これで「リンクからタブを作る」(ADR 008 の構想) が完成する: タブ間で場所を送る・
メモに場所を控える、が全部テキストのコピペになる。

#### URI の読み書きはプロバイダーごとの規則にする (2C-2)

URI の**形** (`<scheme>://<instanceId>/<path>`) は全ソース共通だが、path と query に
何を書くか、それが人間には何と読めるかは**ソースごとに違う**。Pixiv にはタグと
一致モードがあり、SMB にはディレクトリがある。「検索」の意味も違う (Pixiv は
タグ検索、SMB は将来ファイル名検索で、対象は今いるフォルダ以下)。そこで
scheme ごとの規則を `lib/screens/gallery/gallery_uri_dialect.dart` に置く:

```dart
abstract class GalleryUriDialect {
  String describe(Uri uri);                          // 人に見せる文字列
  String? titleFrom(Uri uri, List<ImageSource> it);  // 中身から分かる名前
  List<PlaceLink> get sections;                      // ☰ 上段に出す行き先
  String? get searchHint;                            // null = 検索は無い
  Uri? search(Uri from, String query);               // from = 今いる場所
  List<SearchOption> searchOptions(Uri from);        // 窓の中のトグル
}
```

- **`search` が `from` を取る**のが要。検索の意味は「どこで打ったか」で決まる。
  Pixiv は `from` が検索ページなら `s_mode`/`order` を引き継ぎ (クエリを打ち直す
  たびに完全一致へ戻ったりしない)、SMB は `from` のフォルダを対象にする。
  呼ぶ側は今の URI と文字列を渡すだけで、引き継ぎ規則を知らなくてよい
- **全部 URI だけの純関数**にする。これは都合ではなく要件で、
  [ADR 009](../adr/009-navigation-toolbar.md) の永続化で**復元したタブは接続前に
  自分の名前を言えないといけない**。プロバイダー本体に持たせると接続するまで
  名前が出せない
- 取得しないと分からないもの (作者名、SMB サーバーの愛称) は
  `GallerySession.title` が持ち、**title があればそちらが勝つ** (`placeTitle`)。
  逆に URI から導けるものは title に入れない — 名前の付け方が 2 つあると必ずずれる
- 取得して初めて分かる名前は `titleFrom(uri, items)` で**中身から拾う**。
  作者名は作品 1 件 1 件に載っているので、最初のページが返れば分かる。
  URI 直打ちや復元で開いたときは渡してくれる相手がいないため、この経路が要る。
  遷移元が既に知っている場合 (リンク・ビューア) は先に title を渡す方が勝ち、
  「数字が出てから名前に変わる」ちらつきを避ける。
  `GallerySession.title` は可変で、確定したら `onTitleChanged` →
  `GalleryTab.revision` でヘッダーが追随する
- 2C-3 / 2C-4 でトグルとページ数フィルタを URI のクエリへ移すときも、
  足すのは `describe` の 1 分岐とクエリ 1 個で済む

`describe` と**タブチップの短縮は別物**。チップは隣のタブと**区別**できればよく
幅が無いので末尾 1〜2 段、`describe` は今いる場所を**同定**するので省略しない:

| URI | チップ (非アクティブ / アクティブ) | `describe` |
|---|---|---|
| `smb://1700000000000/books/series/vol2` | `vol2` / `series/vol2` | `books/series/vol2` |
| `pixiv://default/search?word=books&s_mode=s_tag` | `books (部分)` | `books (部分)` |
| `home://default` | `ホーム` | `ホーム` |

検索の注記 (`(部分)`) は**既定と違うときだけ**出す。既定 (完全一致・新着) は
黙っている。「なぜ一覧がこう見えるのか分からなくなる」のがこの UI の典型事故
なので、外れている事実の方を見せる。

#### 検索オプション (完全一致 / 並び順) — 検索に付随

`s_mode` と `order` は検索クエリの一部なので、**検索編集中にのみ**窓の右端に
小さいトグルとして出す。常設すると、検索の無いタブ (SMB・お気に入り・ホーム) で
意味を持たないボタンが並ぶか、タブごとに出たり消えたりして段が落ち着かない。

トグルの中身は `searchOptions(from)` が返す `(label, next)` の組で、ウィジェットは
`s_mode` という名前を知らない。押すと変わるのは**これから出す検索**であって、
今いる場所ではない。

この区別は失敗して学んだ。最初はトグルが「今いる場所の URI」を書き換える実装で、
作者ページで押すと `/user/12345?s_mode=s_tag` になり、`PixivSource` が作者 ID を
`12345?s_mode=s_tag` と読んで落ちた。**オプションは検索のものなので、検索の URI に
だけ乗る**。編集開始時に `searchFrom(場所, '')` で「語の無い検索」を作り、トグルは
それだけを書き換え、確定時に語を載せる。場所の URI は最後まで汚れない。

#### ページ数フィルタ — 一覧に付随 (検索オプションとは性質が違う)

「N 枚以上の作品だけ表示」は検索オプションに似て見えるが、**表示フィルタ**
(手元で絞るだけ。検索結果に限らず作者ページでもブックマークでも効く) なので、
検索ではなく一覧に付随させる。窓の右端の**常設ボタン**にする:

- 未使用時はフィルタアイコン、**使用中は `3+` のようなバッジに変わる**。
  「なぜ一覧が減っているのか」が常に見えるようにする — フィルタを忘れて
  「作品が消えた」と思うのがこの UI の典型事故なので
- タップでポップアップ: **すべて / 3+ / 5+ / 10+ / 20+**
- `N+` は「N 枚**以上**」(pageCount >= N)。現行実装は `>N` (超) なので、
  移行時に境界を >= に揃える
- Pixiv タブでのみ表示 (他ソースにページ数の概念が無い)。将来 SMB の
  「動画のみ」等も同じ位置に入る

#### スクロールでの自動隠し

2 段 (~96dp) は常設できない: タブレット横画面で見えるサムネイルは 5 列 x 2.7 行
しかない (これが 2B-10 でストリップを AppBar に統合した理由でもある)。
下スクロールで両段とも隠れ、上スクロールで戻す。隠れている間もシステム戻るは
効くので、ナビ手段が消えるわけではない。

#### ☰ (ハンバーガー) と + の役割分担

- `+` = 新しいタブを開く (現状のまま)
- `☰` = **今のタブの中の行き先 + アプリ操作**。Chrome の ☰ に「ページ内の
  移動とアプリ操作が同居」しているのと同じ形:
  - 上段 (ソース固有): Pixiv タブなら セクション (トップ / ブックマーク)。
    2B-10 以前に AppBar メニューだったものがここへ帰る。ボディのヘッダーに
    仮住まいしていた「Pixiv ▾」は廃止。タップは `tab.navigate` (履歴に積む)
  - 下段 (共通): 再読み込み、設定 (現在 `+` の中にいるが「タブを開く」では
    ないのでこちらへ移す)、将来の履歴一覧など
  - SMB・お気に入り・ホームのタブでは上段が無く、共通部だけになる

#### 残る検討

- 履歴一覧 (数段飛ばしの戻り)。← の長押しか ☰ 内。今回は配線しない
- **作品 URL の貼り付け**。2C-3 以前は Pixiv の検索欄が
  `pixiv.net/artworks/<id>` を解釈してビューアを直接開いていた。作者 URL
  (`/users/<id>`) は場所なので窓に移したが、作品は**この app が「居られる」
  場所ではない**ので移し先が無く、落とした。繋ぎを作らなかったのは、
  ビューアをタブ化すれば `pixiv://default/artworks/<id>` が場所として成立し、
  ただで戻ってくるから。ビューアのタブ化は「リストの中の位置」を履歴エントリに
  どう載せるかという別の設計判断 (ADR 008 の拡張) なので、独立した題材として扱う

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
   `anchor`/`thumbLoader` を所有)、ソースは無状態の `loadPage(cursor)`。
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
6. **表示位置はアイテムのアンカー** (`itemId` + `rowFraction`) で保持する。ピクセル値では
   画面の縦横変更で表示項目がズレるため。順番でなく id を持つのは、表示専用フィルタで
   表示列と `loaded` がズレるから。詳細は上記「4.」。

## 残る検討 (実装時に確定)

- **非画像アイテム**: SMB のディレクトリ/動画は `loaded` に混在する `ImageSource` (メタデータ
  フラグ) のまま。tileBuilder が描画を、タップ時にディレクトリならその dir URI へ
  `tab.navigate` (同一タブの履歴に積む)。現行のメタデータ分岐を踏襲する方向。
- `GalleryTabController` の UI (タブバー・並び・閉じる操作・複製) の具体。
- ~~「進む」操作をどの入力に割り当てるか~~ → ツールバーの → に確定 (上記 7、ADR 009)。
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
   | 2B-5 | 表示位置をアイテムのアンカーで保存・復元 (上記 4)。(a) 回転時のズレを直し、(b) 履歴復元の配管を通す | **(a) を修正** |
   | 2B-6 | `GallerySession.fromUri(uri, registry)` ファクトリ (URI 駆動生成) | 不変 |
   | 2B-7 | 両画面の残り glue を共通 `GalleryView` ウィジェットへ (tileBuilder / AppBar は注入) | 不変 |
   | 2B-8 | `GalleryTab` (id + history + index) を導入、画面は `tab.current` を見る | 不変 (履歴長 1) |
   | 2B-9 | 画面内ナビを `Navigator.push` → `tab.navigate(uri)`。戻るは履歴 pop、先頭で画面 pop | **変化** |
   | 2B-10 | `GalleryTabController` + タブバー UI。複製・リンクからのタブ生成 | **変化** |

   2B-7 を 2B-9 より先に置くのは、ナビモデルの変更を 1 箇所で済ませるため。
4. **フェーズ 2C**: ナビゲーションツールバー (上記 7、[ADR 009](../adr/009-navigation-toolbar.md))。
   2B と同じく段階化し、各段で実機 verify:

   | | 内容 | 挙動 |
   |---|---|---|
   | 2C-1 | ツールバーの器: ← → [タイトル表示のみ] ☰。← は goBack、→ は forward() を配線 | **変化** (進むの新設) |
   | 2C-2 | 窓の編集モード: タップで URI 全選択、URI 入力で移動、テキストで検索 | **変化** |
   | 2C-3 | 検索オプション (完全/新着) を窓へ、セクションメニューを ☰ へ。Pixiv ボディのヘッダーを全撤去 | 移設 |
   | 2C-4 | ページ数フィルタをボタン + バッジ化 (すべて/3+/5+/10+/20+、境界を >= に) | **変化** (境界と UI) |
   | 2C-5 | スクロールで両段を自動隠し | **変化** |

   2C-1 を先頭に置くのは、器さえあれば進む/戻るが即使えるようになり、
   窓の中身 (2C-2 以降) はその上に順に載るため。
5. **フェーズ 3**: 残りソース (お気に入り・DL 済み等) を仮想列に移行。URI/キャッシュキー統一。
