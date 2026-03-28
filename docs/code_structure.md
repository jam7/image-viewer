# Code Structure

```
lib/
├── main.dart                          # エントリポイント（runApp のみ）
├── app.dart                           # MaterialApp定義、テーマ、ルーティング
├── models/                            # データモデル
│   ├── image_source.dart              # 画像ソース + ImageSourceType enum
│   └── server_config.dart             # サーバー接続情報
├── services/                          # ビジネスロジック（UIに依存しない）
│   ├── sources/                       # プロトコル別の画像取得
│   │   ├── image_source_provider.dart # 共通インターフェース（abstract class）
│   │   ├── source_registry.dart       # sourceKey → Provider 解決、ログイン管理
│   │   ├── pixiv_source.dart          # Pixiv API経由の画像取得
│   │   ├── smb_source.dart            # SMB経由の画像取得（ZIP対応）
│   │   ├── http_source.dart
│   │   ├── google_drive_source.dart
│   │   └── onedrive_source.dart
│   ├── pixiv/                         # Pixiv API連携
│   │   ├── pixiv_web_client.dart      # WebView経由のAPI通信（Cookie認証）
│   │   └── pixiv_api_client.dart      # Pixiv Web API ラッパー
│   ├── cache/                         # 3層キャッシュ
│   │   ├── memory_cache.dart          # L1: メモリ（LRU）
│   │   ├── disk_cache.dart            # L2: ディスク（LRU、500MB〜5GB）
│   │   ├── download_store.dart        # L3: DL永久保存（トグル式）
│   │   ├── cache_manager.dart         # L1→L2→L3統合検索
│   │   └── cache_metadata.dart        # メタデータモデル
│   ├── favorites/
│   │   └── favorites_store.dart       # お気に入り（URLのみ記録、トグル式）
│   ├── prefetch/
│   │   └── prefetch_manager.dart      # スライディングウィンドウ制御
│   ├── thumbnail/
│   │   └── thumbnail_loader.dart      # サムネイルバッチ読み込み（キャンセル・リトライ管理）
│   └── video/
│       ├── smb_proxy_server.dart      # SMB→HTTP プロキシ（media_kit 用、localhost:ランダムポート、トークン認証）
│       └── video_thumbnail_service.dart # 動画サムネイルキャプチャ（media_kit Player 再利用）
├── screens/                           # 画面（画面固有のウィジェットも同フォルダに置く）
│   ├── gallery/gallery_screen.dart    # Pixiv サムネイル一覧（タブ独立、per-tab state）
│   ├── gallery/smb_gallery_screen.dart # SMB ディレクトリブラウズ（ZIP/PDF/画像/動画/フォルダ）
│   ├── viewer/viewer_screen.dart      # フルスクリーン画像ビューア（スワイプ/キーボード操作）
│   ├── video/video_player_screen.dart # 動画プレーヤー（media_kit、ESC/Space/矢印キー操作）
│   ├── pixiv/pixiv_login_screen.dart  # Pixivログイン（プラットフォーム別WebView）
│   └── settings/settings_screen.dart  # 接続先設定
└── widgets/                           # 複数画面で共有するウィジェット
    ├── progressive_image.dart         # 3段階ロード画像ウィジェット
    └── thumbnail_result.dart          # サムネイル取得結果（sealed class）

packages/
└── archive_reader/                    # Range Read ベースのアーカイブリーダー
    └── lib/src/zip/zip_reader.dart    # ZIP セントラルディレクトリ解析 + 個別エントリ取得
```

## 配置ルール

- 画像取得は `ImageSourceProvider` インターフェースで抽象化し、プロトコル毎に実装を差し替え可能
- 画面固有のウィジェットは `screens/<画面名>/` に、2箇所以上で使うものは `widgets/` に置く
