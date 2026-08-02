# Architecture Decision Records

横断的な設計判断を記録する。コンポーネント固有の判断は各アーキテクチャドキュメントに記載。

| # | 決定 | 状態 |
|---|---|---|
| [001](001-pdf-renderer.md) | PDF レンダラーに pdfrx を採用 | Accepted |
| [002](002-video-proxy.md) | 動画再生に SMB→HTTP プロキシ方式を採用 | Accepted |
| [003](003-cache-layers.md) | 3層キャッシュアーキテクチャ | Accepted |
| [004](004-pixiv-auth.md) | Pixiv 認証に WebView 2台構成を採用 | Accepted |
| [005](005-webview-platform.md) | WebView のプラットフォーム別実装 | Accepted |
| [006](006-thumbnail-source-generalization.md) | ギャラリーのサムネイル取得を ImageSourceProvider に一般化 | Accepted |
| [007](007-virtualized-gallery.md) | ギャラリーを仮想化ページリストモデルに統一 (閲覧状態はタブ所有) | Accepted (決定 4 は 008 で改訂) |
| [008](008-tab-identity-and-history.md) | タブ identity をタブ ID とし、URI はタブ内ナビ履歴の要素とする | Accepted |
| [009](009-navigation-toolbar.md) | 戻る・進むはツールバーの明示ボタンにする (Android 15 で端と長押しが使えない) | Accepted |
| [010](010-viewer-as-a-place.md) | ビューアをルートではなくタブの中の場所にする (前後は履歴の直前から) | Accepted (実装済み) |
| [011](011-thumbnail-pull-pipeline.md) | サムネイルをプル型にする (画面が要求し、優先度つきで応える) | Accepted |
| [012](012-pixels-at-display-size.md) | 画素数は表示サイズで決める (ズームは取り直しで応える) | Proposed |
