# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Flutter製のクロスプラットフォーム画像ビューアアプリ（iOS/iPad/Android/Windows）。
リモートサーバーから画像をストリーミング表示し、ローカルキャッシュを最小限に抑える。

## コーディングルール

### 並行実行の安全性（必須）

- **インスタンス変数で非同期メソッド間の状態を共有しない**。複数の async 呼び出しが並行実行される場合、インスタンス変数は競合する。戻り値やレコード型で結果を返すこと
- サムネイルダウンロード等のバッチ処理は並行実行される前提で設計する
- 共有リソース（ファイル、DB）へのアクセスは排他制御する（`_isFlushing` パターン等）

### エラーハンドリング（必須）

- **アプリ・ライブラリ共通**: `package:logging` を使用。`print` は使わない（出力先は `main.dart` のハンドラで設定）
- **アプリ（lib/ 以下）**: catch ブロックでは必ず `_log.warning('message', e, st)` でログ出力する。`catch (_)` で握りつぶさない。画面に表示するエラーとログ出力の両方を行う
- **ライブラリ（dart_smb2/ 等）**: 例外を throw/rethrow で呼び出し元に返す。フォールバック処理で catch する場合は具体的な型（`on FormatException` 等）でキャッチし、`catch (_)` で握りつぶさない
- **dart_smb2 のログレベル**: `main.dart` で設定。接続・認証など頻度の低いログ（`Smb2Client`）は INFO 許可。大量に出る I/O ログ（`Smb2Multiplexer`, `Smb2FileReader`, `Smb2Tree`）は WARNING 以上に制限
- **ログレベル変更時の原則**: ライブラリのログを抑制する場合、必要なログまで抑制しないか確認する。ワークアラウンド（warning に昇格、アプリ層で代替出力）ではなく、ログレベル設定自体を見直す

### バグ調査の進め方（必須）

- クラッシュやバグが報告されたら、**まずログを読んで根本原因を特定する**。ガードやフォールバックで隠してはいけない
- ログから原因が特定できない場合は、**該当箇所にログを追加して再実行し、原因を絞り込む**。推測で修正しない
- 原因が特定できてから修正する。修正が正しいことをログや再現手順で確認する

### git push の禁止（必須）

- **`git push` はユーザーから「push して」と明示的に指示されるまで絶対にしない**
- commit は自由にしてよいが、push は指示があるまで行わない
- commit コマンドに `&& git push` を含めない
- push 済みだと amend ができず force push が必要になる。履歴整理の妨げになる

### 実装時の説明責任

- 新機能や設計変更時は、方針と考え方を説明してから実装する
- pull した変更をレビューし、上記ルールに違反するコードがあれば指摘・修正する

## 開発コマンド

```bash
flutter analyze          # 静的解析
flutter test             # 全テスト実行
flutter test test/widget_test.dart  # 単一テスト実行
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8 # flutterの出力のパースをutf8に
flutter run -d windows 2>&1 | Tee-Object -FilePath "C:\Users\jam\flutter_log.txt"  # Windows向け（PowerShell、ログは C:\Users\jam\flutter_log.txt）
flutter run -d <iPad ID> # iOS/iPad向け（flutter devices でID確認）
flutter run -d chrome    # Web向け（デバッグ用）
```

### iOS/iPad 開発メモ

- 初回: `ios/DeveloperSettings.xcconfig` を作成し `DEVELOPMENT_TEAM = <your team ID>` を記載（gitignore済み）
- iPadの Developer Mode をオンにし、証明書を信頼する必要あり（設定 > 一般 > VPNとデバイス管理）
- Wi-Fiデバッグ可能（Xcode > Devices and Simulators でネットワーク接続を有効化）
- `project.pbxproj` は `--assume-unchanged` 設定済み（Xcodeが頻繁に書き換えるため）
  - 正当にコミットしたい時: `git update-index --no-assume-unchanged ios/Runner.xcodeproj/project.pbxproj`
  - 再設定: `git update-index --assume-unchanged ios/Runner.xcodeproj/project.pbxproj`

## コード構成

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

- 画像取得は `ImageSourceProvider` インターフェースで抽象化し、プロトコル毎に実装を差し替え可能
- 画面固有のウィジェットは `screens/<画面名>/` に、2箇所以上で使うものは `widgets/` に置く

## アーキテクチャ

詳細は `docs/` 以下のドキュメントを参照。

| ドキュメント | 内容 |
|---|---|
| [docs/thumbnail_architecture.md](docs/thumbnail_architecture.md) | ThumbnailLoader、バッチ処理、動画サムネイル、プロキシ |
| [docs/viewer_architecture.md](docs/viewer_architecture.md) | ViewerScreen、VideoPlayerScreen、プリフェッチ、キャッシュ、PDF/ZIP 処理 |
| [docs/pixiv_auth.md](docs/pixiv_auth.md) | Pixiv 認証フロー（WebView 2台構成） |

### キャッシュ概要

| 層 | 保存先 | 内容 | 排出 |
|---|---|---|---|
| L1 | メモリ | デコード済み画像 〜10枚 | LRU自動 |
| L2 | ディスク | 圧縮画像 500MB〜5GB（設定可） | LRU自動 |
| L3 | ディスク | ユーザーが明示的にDLした作品 | 手動トグル |
| お気に入り | JSON | URL+メタデータのみ（画像なし） | 手動トグル |

CacheManager が L1→L2→L3→ネットワークの順に検索。キー命名: `thumb:<id>`（サムネイル）、`full:<id>`（表示用データ）。

### Pixiv 認証

- WebView 2台構成（ログイン用 + API 用）、Cookie ストア共有
- `webview_flutter`（iOS/Android）、`webview_windows`（Windows）
- 詳細は [docs/pixiv_auth.md](docs/pixiv_auth.md)

### SMB

- `dart_smb2`（自作）で SMB 2.0/2.1 対応
- ZIP: `archive_reader`（自作）で Range Read ベースの個別エントリ展開
- PDF: `pdfrx`（PDFium）で `PdfDocument.openFile` → ページレンダリング
- 動画: `media_kit` + `SmbProxyServer`（localhost HTTP プロキシ）

### 認証情報の保存場所

| プラットフォーム | Pixiv セッション | SMB パスワード |
|---|---|---|
| Windows | WebView2 ユーザーデータフォルダ | Credential Manager |
| iOS/macOS | WKWebView サンドボックス | Keychain |
| Android | WebView サンドボックス | EncryptedSharedPreferences |

## 主要パッケージ

- `webview_flutter`: iOS/Android 用 WebView（ログイン + API）
- `webview_windows`: Windows 用 WebView2（ログイン + API）
- `dart_smb2`: SMB 2.0/2.1 クライアント（自作、dart_smb2/ ディレクトリ）
- `archive_reader`: Range Read ベースの ZIP リーダー（自作、packages/archive_reader/）
- `pdfrx`: PDF ページレンダリング（PDFium ベース、upstream 版）
- `media_kit` / `media_kit_video`: 動画再生（libmpv / FFmpeg ベース、ほぼ全フォーマット対応）
- `flutter_secure_storage`: パスワード安全保管（Keychain/Credential Manager）
- `dio`: HTTP通信（画像ダウンロード等）
- `path_provider`: アプリ固有ディレクトリ取得
- `crypto`: ハッシュ計算
