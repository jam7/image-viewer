# ギャラリー2画面の共通化 — 設計

Pixiv ギャラリー (`gallery_screen.dart`) と SMB ギャラリー (`smb_gallery_screen.dart`)
の重複を、部品を少しずつ抽出して共通化するリファクタの設計。挙動不変を原則とし、
着手前に characterization テストで回帰を防ぐ (spec-dev 軽量: 要件・仕様フェーズは
挙動不変のため省略し、本 design.md + ADR が中心)。

- 横断的な設計判断は [ADR 006](../adr/006-thumbnail-source-generalization.md)。
- 完了後、恒久的な設計は [thumbnail_architecture.md](../thumbnail_architecture.md) に統合する。

## 背景と目的

2 画面は本来共通化すべき「足回り」を重複実装している。別画面にしたため共通化されず、
サムネイル取得に至っては Pixiv 側だけ直列 (低速、[P1](../../TODO.md)) という劣化コピーに
なっている。目的は次の 2 つ。

1. 足回り (グリッド・キーボード/スクロール・pop) を共有ウィジェットへ抽出して重複を消す。
2. サムネイル取得エンジン (`ThumbnailLoader`) を SMB 専用から `ImageSourceProvider`
   一般に広げ、Pixiv にも使わせる (= P1 の解消)。

## 現状: 共通する足回りと、分岐する中身

| 観点 | Pixiv (`gallery_screen.dart`) | SMB (`smb_gallery_screen.dart`) |
|---|---|---|
| キーボード/スクロール/マウス戻る | `_onKeyEvent` / `_scrollBy` / `_onPointerDown` (ほぼ同一) | 同左 (ほぼ同一) |
| グリッド | `Scrollbar` + `GridView` + `galleryGridDelegate` + empty/loading | 同左 |
| サムネイル取得 | **インライン直列ループ** (`_loadThumbnails`) | `ThumbnailLoader` (並列バッチ + 動画 + cancel/retry) |
| サムネイル状態の型 | 生の `Uint8List` | sealed な `ThumbnailResult` |
| タイル描画 | 画像 + 複数ページバッジ | フォルダ/動画/アーカイブ/壊れ アイコン + 再生オーバーレイ |
| コンテンツモデル | タブ + 検索 + フィルタ + 無限ページネーション | ディレクトリツリー (ページネーションなし) |
| タップ | 常にビューア | ディレクトリ移動 / 動画プレーヤー / ビューア |

共通なのは足回り。分岐するのはコンテンツモデル・サムネイルエンジン・タイル描画・タップ。
**分岐部分は各画面に残す。** 共通化するのは足回りとサムネイルエンジンだけ。

## ターゲット設計

### 抽出する共有ウィジェット (Step 1)

基底クラス (継承) は採らない。Flutter の `State` 継承は fragile base class 問題を招き、
タブ/検索を持つ Pixiv と持たない SMB を 1 基底に押し込むと分岐だらけになる。代わりに
**presentation を担う widget を注入式で組み合わせる**。

| ウィジェット | 責務 | パラメータ (概略) |
|---|---|---|
| `GalleryKeyboardScrollable` | `Focus` + `Listener` + キー処理 + `_scrollBy` + マウス戻る + スワイプ pop | `focusNode`, `scrollController`, `onPop`, `child` |
| `GalleryGrid` | `Scrollbar` + `GridView` + gridDelegate + empty/loading/error + バッチ/追加ロードのトリガ | `itemCount`, `tileBuilder(index)`, `onTap`, `scrollController`, `isLoading`, `error`, `onLoadMore` |

- `GalleryGrid` は `ThumbnailResult` か `Uint8List` かを知らない。タイル生成は各画面の
  `tileBuilder` に委ねる (アイコン種別・バッジの差分は本質なので共通化しない)。
- 各画面はコンテンツ管理 (タブ/検索/ページネーション or ディレクトリ) を State に残す。

#### 入力操作は統合してから抽出する (Step 1a → 1b)

2 画面の入力処理はほぼ同一だが、別々に作った経緯で細かく分岐していた。同じ操作感に
そろえるため、`GalleryKeyboardScrollable` にパラメータで差分を持たせるのではなく、
**先に両画面の挙動を superset に統合** (Step 1a、挙動変化) してから
**パラメータ無しの共有ウィジェットへ抽出** (Step 1b、挙動不変) する。

| 操作 | 統合前 Pixiv | 統合前 SMB | 統合後 (両画面) |
|---|---|---|---|
| 矢印/Page/Space/Home/End スクロール | あり | あり | あり |
| Escape で pop | あり | あり | あり |
| マウス戻るボタンで pop | あり | あり | あり |
| Backspace で pop | なし | あり | **あり** |
| 横スワイプ (velocity>300) で pop | あり | なし | **あり** |
| primaryFocus ガード (入力中はキー無効) | あり | なし | **あり** (SMB では実質 no-op) |
| 二重 pop ガード (`_popOnce`) | なし | あり | **あり** |

- primaryFocus ガードと二重 pop ガードは両画面に付けてもほぼ挙動不変 (SMB に奪い合う
  TextField は無く、二重 pop ガードは稀な同時 pop を防ぐだけ)。
- Backspace pop と横スワイプ pop は挙動変化。Step 1a で characterization に新挙動を
  ピンしてから入れる。
- 統合後は `GalleryKeyboardScrollable` に真偽フラグが不要になり、`onPop` (各画面が
  `_popOnce` を渡す)・`focusNode`・`scrollController`・`child` だけで済む。

### サムネイルエンジンの一般化 (Step 2 = P1)

`ThumbnailLoader` を SMB 依存から `ImageSourceProvider` 一般へ広げる。詳細な判断は
[ADR 006](../adr/006-thumbnail-source-generalization.md)。要点:

- **命名は不変。** 一般化するのは「取得元」であって「対象がサムネイルであること」は
  変わらない。`ThumbnailLoader` / `fetchThumbnail` / `ThumbnailResult` はそのまま。
  変わるのは `ThumbnailLoader` の `final SmbSource source` → `final ImageSourceProvider source`。
- **サムネイル生成の責務はソースに集約する。** 動画フレームのキャプチャ
  (`SmbProxyServer` + `VideoThumbnailService` + `resizeToThumbnail`) を
  `ThumbnailLoader` から `SmbSource.fetchThumbnail` へ移す。「元データからサムネイルを
  作る」= `fetchThumbnail` の契約そのもの。結果、`ThumbnailLoader` は動画/PDF/ZIP を
  一切知らない汎用実行器 (並列バッチ + キャッシュ + cancel/retry + 例外→結果マッピング)
  になり、Pixiv がそのまま再利用できる。
- **「利用不能」は型付き結果として残す。** `fetchThumbnail` は cheaply に作れない場合
  `ThumbnailNotSupportedException` を throw し、`ThumbnailLoader` が
  `ThumbnailFailed(notSupported)` にマップする。**呼び側 (ギャラリー) がその描画
  (アイコン等) を決める。** `ThumbnailLoader` がフル画像で勝手に代替することはしない
  (数 MB のフル DL はサムネイルの目的に反する)。Pixiv の `fetchThumbnail` は
  notSupported を投げない (常に 250px を返す) ので、notSupported 分岐は発火しないだけ。
- **中断 (cancel) はソースへ委譲する。** 動画再生前の「SMB 接続/プレーヤ解放」は、
  `ImageSourceProvider` に既定 no-op の中断フックを 1 つ足し、`ThumbnailLoader.cancel()`
  から呼ぶ。`SmbSource` がそれで動画サービスを dispose する。
- **直列化ヒントは残す。** 「重い取得は直列」の最適化は `ImageSource.metadata['isVideo']`
  (モデル層の汎用ヒント) を見て維持する。生成方法は知らないが、スケジューリングだけ行う。

### ソース別の `fetchThumbnail` (一般化後)

| ソース | サムネイルの作り方 | notSupported を投げる場合 |
|---|---|---|
| `SmbSource` | EXIF サムネ / リサイズ / ZIP 先頭画像 / PDF ページ0 / **動画フレーム** | 未 DL PDF、画像無し ZIP、ZIP in ZIP 等 |
| `PixivSource` | 一覧 API の 250px URL を DL | なし (常に返せる) |

## 影響範囲

### Step 1a (挙動変化: 入力操作の統合)
- 変更: `gallery_screen.dart` (Backspace pop・`_popOnce` 追加)、
  `smb_gallery_screen.dart` (primaryFocus ガード・横スワイプ pop 追加)
- テスト: characterization に新挙動 (Pixiv の Backspace pop、SMB の横スワイプ pop) を追加

### Step 1b (挙動不変: ウィジェット抽出)
- 新規: `lib/screens/gallery/widgets/gallery_keyboard_scrollable.dart`, `gallery_grid.dart`
- 変更: `gallery_screen.dart`, `smb_gallery_screen.dart` (抽出先を使う形に)

### Step 2 (挙動変化 = P1)
- 変更: `thumbnail_loader.dart` (source 型 widening、動画パス削除、proxyServer フィールド削除、
  cancel をソース委譲へ)
- 変更: `image_source_provider.dart` (`ThumbnailNotSupportedException` を interface 側へ移動、
  中断フック追加)
- 変更: `smb_source.dart` (`fetchThumbnail` が動画も処理。proxyServer/VideoThumbnailService を
  注入。`resizeToThumbnail` は private 化)
- 変更: Pixiv ギャラリー (`ThumbnailLoader` + `ThumbnailResult` 描画へ移行)
- 変更: `SmbSource` 生成箇所は 2 つ (`source_registry.dart` / `home_screen.dart`)。
  app 単一の `SmbProxyServer` (`app.dart`) をこの 2 箇所へ通す注入経路が要る
- 変更: `docs/thumbnail_architecture.md`

## 検証方針

- **Step 0 (済)**: `test/screens/gallery/gallery_characterization_test.dart` で両画面の
  grid 状態・キーボード/スクロール・pop を pin。Step 1/2 の各コミット後に green を維持。
- **Step 1a**: 挙動変化 (入力統合)。新挙動を characterization に追加してから実装し、
  既存 + 新規テストが green であることで verify。
- **Step 1b**: 挙動不変 (ウィジェット抽出)。characterization が green なら OK。
- **Step 2**: 挙動変化。characterization に加え、
  - 動画サムネイルの生成・**再生前 cancel での接続解放**を実機で verify (proxy セッション/
    トークン無効化が絡むため、テストだけでは不十分)。
  - Pixiv サムネイルが並列化され速くなったことをログの所要時間で確認 (P1)。
  - notSupported タイル (未 DL PDF 等) がビューア/プレーヤ復帰後にリトライされる挙動を確認。

## 進め方

fix-loop 方式で 1 抽出ずつ。1 コミット 1 変更を守り、各コミットで characterization を実行する。
Step 1 → Step 2 の順。Step 2 の動画パス移設は挙動変化を伴うため独立コミットにし、
verify を挟む。

## 未決事項・リスク

- 中断フックの API 形 (`cancelThumbnailWork()` を interface に足すか、ソース内 generation で
  済ませるか) は Step 2 着手時に確定する。
- 動画キャプチャ移設は proxy セッションの寿命管理に触れるため回帰リスクが最も高い。
  ここだけ切り出して verify する。
- `GalleryGrid` の「追加ロードのトリガ」は Pixiv (無限スクロール) と SMB (バッチ dispatch) で
  意味が異なる。トリガ発火は共通化するが、発火後の動作はコールバックで各画面に委ねる。
