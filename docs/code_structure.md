# Code Structure

```
lib/
├── main.dart                          # エントリポイント (runApp のみ)
├── app.dart                           # MaterialApp定義、テーマ、ルーティング
├── models/                            # データモデル
│   ├── image_source.dart              # 画像ソース + ImageSourceType enum
│   └── server_config.dart             # サーバー接続情報
├── services/                          # ビジネスロジック (UIに依存しない)
│   ├── sources/                       # プロトコル別の画像取得
│   │   ├── image_source_provider.dart # 共通インターフェース (abstract class)
│   │   ├── source_registry.dart       # sourceKey → Provider 解決、ログイン管理
│   │   ├── pixiv_source.dart          # Pixiv API経由の画像取得
│   │   ├── smb_source.dart            # SMB経由の画像取得 (ZIP対応)
│   │   ├── favorites_source.dart      # ソース横断お気に入り (各アイテムの元ソースに委譲)
│   │   ├── home_source.dart           # ホーム (項目を持たない。タブにするための器)
│   │   ├── http_source.dart
│   │   ├── google_drive_source.dart
│   │   └── onedrive_source.dart
│   ├── pixiv/                         # Pixiv API連携
│   │   ├── pixiv_web_client.dart      # WebView経由のAPI通信 (Cookie認証)
│   │   └── pixiv_api_client.dart      # Pixiv Web API ラッパー
│   ├── cache/                         # 3層キャッシュ
│   │   ├── memory_cache.dart          # L1: メモリ (LRU)
│   │   ├── keyed_file_store.dart      # L2/L3 の実体 (ファイル + 索引)
│   │   ├── disk_cache.dart            # L2: ディスク (LRU、500MB〜5GB)
│   │   ├── download_store.dart        # L3: DL永久保存 (トグル式)
│   │   ├── cache_manager.dart         # L1→L2→L3統合検索
│   │   └── cache_metadata.dart        # メタデータモデル
│   ├── favorites/
│   │   └── favorites_store.dart       # お気に入り (URLのみ記録、トグル式)
│   ├── prefetch/
│   │   └── prefetch_manager.dart      # スライディングウィンドウ制御
│   ├── thumbnail/
│   │   └── thumbnail_loader.dart      # サムネイルバッチ読み込み (キャンセル・リトライ管理)
│   └── video/
│       ├── smb_proxy_server.dart      # SMB→HTTP プロキシ (media_kit 用、localhost:ランダムポート、トークン認証)
│       └── video_thumbnail_service.dart # 動画サムネイルキャプチャ (media_kit Player 再利用)
├── screens/                           # 画面 (画面固有のウィジェットも同フォルダに置く)
│   ├── gallery/                       # タブ方式のギャラリー (ADR 007 / ADR 008)
│   │   ├── gallery_tabs_screen.dart   # アプリのルート。開いているタブのホスト
│   │   ├── gallery_tab_controller.dart # タブ集合とアクティブタブ
│   │   ├── gallery_tab.dart           # 1 タブ = id + 履歴スタック
│   │   ├── gallery_session.dart       # 1 セッション = 1 つの「場所」の閲覧状態
│   │   ├── gallery_uri.dart           # 場所のアドレス (smb:// pixiv:// fav:// home://)
│   │   ├── gallery_tab_opener.dart    # URI → セッション / タブ (registry 解決)
│   │   ├── home_gallery_body.dart     # ホーム: サービスとサーバーの一覧
│   │   ├── smb_gallery_body.dart      # SMB ディレクトリブラウズ
│   │   ├── pixiv_gallery_body.dart    # Pixiv 一覧 (トップ/検索/作者/ブックマーク)
│   │   ├── favorites_gallery_body.dart # ソース横断お気に入り
│   │   └── widgets/                   # 全ボディ共通 (GalleryView / GalleryGrid / タブストリップ)
│   ├── viewer/viewer_screen.dart      # フルスクリーン画像ビューア (スワイプ/キーボード操作)
│   ├── video/video_player_screen.dart # 動画プレーヤー (media_kit、ESC/Space/矢印キー操作)
│   ├── pixiv/pixiv_login_screen.dart  # Pixivログイン (プラットフォーム別WebView)
│   └── settings/settings_screen.dart  # 接続先設定
└── widgets/                           # 複数画面で共有するウィジェット
    ├── progressive_image.dart         # 3段階ロード画像ウィジェット
    └── thumbnail_result.dart          # サムネイル取得結果 (sealed class)

packages/
└── archive_reader/                    # Range Read ベースのアーカイブリーダー
    └── lib/src/zip/zip_reader.dart    # ZIP セントラルディレクトリ解析 + 個別エントリ取得
```

## 配置ルール

- 画像取得は `ImageSourceProvider` インターフェースで抽象化し、プロトコル毎に実装を差し替え可能
- 画面固有のウィジェットは `screens/<画面名>/` に、2箇所以上で使うものは `widgets/` に置く
