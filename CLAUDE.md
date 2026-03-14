# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Flutter製のクロスプラットフォーム画像ビューアアプリ（iOS/Android/Windows）。
リモートサーバーから画像をストリーミング表示し、ローカルキャッシュを最小限に抑える。

## 開発コマンド

```bash
flutter analyze          # 静的解析
flutter test             # 全テスト実行
flutter test test/widget_test.dart  # 単一テスト実行
flutter run -d windows   # Windows向けビルド＆実行（Windows側で実行）
flutter run -d chrome    # Web向け（デバッグ用）
```

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
│   │   ├── http_source.dart
│   │   ├── smb_source.dart
│   │   ├── google_drive_source.dart
│   │   └── onedrive_source.dart
│   ├── pixiv/                         # Pixiv API連携
│   │   ├── pixiv_auth.dart            # OAuth 2.0 + PKCE認証
│   │   ├── pixiv_token_store.dart     # トークン永続化
│   │   └── pixiv_api_client.dart      # App API通信 + 画像DL
│   ├── cache/                         # 3層キャッシュ
│   │   ├── memory_cache.dart          # L1: メモリ（LRU）
│   │   ├── disk_cache.dart            # L2: ディスク（LRU、500MB〜5GB）
│   │   ├── download_store.dart        # L3: DL永久保存（トグル式）
│   │   ├── cache_manager.dart         # L1→L2→L3統合検索
│   │   └── cache_metadata.dart        # メタデータモデル
│   ├── favorites/
│   │   └── favorites_store.dart       # お気に入り（URLのみ記録、トグル式）
│   └── prefetch/
│       └── prefetch_manager.dart      # スライディングウィンドウ制御
├── screens/                           # 画面（画面固有のウィジェットも同フォルダに置く）
│   ├── gallery/gallery_screen.dart    # サムネイル一覧
│   ├── viewer/viewer_screen.dart      # フルスクリーン画像ビューア
│   └── settings/settings_screen.dart  # 接続先設定
└── widgets/                           # 複数画面で共有するウィジェット
    └── progressive_image.dart         # 3段階ロード画像ウィジェット
```

- 画像取得は `ImageSourceProvider` インターフェースで抽象化し、プロトコル毎に実装を差し替え可能
- 画面固有のウィジェットは `screens/<画面名>/` に、2箇所以上で使うものは `widgets/` に置く

## アーキテクチャ

### 画像ロードパイプライン（3段階）

```
BlurHash表示（即座、~30バイト）
    ↓
サムネイル取得（50〜100KB）
    ↓
フル解像度取得（Range Request でストリーミング）
    ↓
ズーム時 → リージョンデコード（可視領域のみ）
```

### プリフェッチ（スライディングウィンドウ方式）

```
[破棄][ N-2 ][ N-1 ][ 現在 ][ N+1 ][ N+2 ][ N+3 ][未取得]
                       ↑表示中
         ← 後方2枚 →         ← 前方3枚 →
```

- 前方: 3〜5枚先までプリフェッチ（近いほど高優先度）
- 後方: 1〜2枚をキャッシュ保持
- 高速スクロール中はサムネイルのみ取得し、停止後にフル解像度を取得

### キャッシュ（3層 + お気に入り）

| 層 | 保存先 | 内容 | 排出 |
|---|---|---|---|
| L1: 短期 | メモリ | デコード済み画像 〜10枚 | LRU自動 |
| L2: 中期 | ディスク | 圧縮画像 500MB〜5GB（設定可） | LRU自動 |
| L3: DL | ディスク | ユーザーが明示的にDLした画像 | 手動トグル |
| お気に入り | JSON | URL+メタデータのみ（画像なし） | 手動トグル |

- CacheManager が L1→L2→L3→ネットワークの順に検索
- キー命名: `thumb:<imageId>` / `full:<imageId>`
- メタデータは `_metadata.json` でatomic write管理

### ネットワーク

- HTTP/2 マルチプレクシング優先（1接続で複数ストリーム、優先度制御可能）
- HTTP/1.1 フォールバック時は同一ホストに4〜6本のコネクションプール
- 優先度キュー: 表示中画像 > 次の画像 > 先読み画像

### メモリ管理

- サブサンプリング: 画面サイズに応じて縮小デコード（メモリ大幅削減）
- RGB565フォーマット: 透過不要な画像は2バイト/ピクセルで50%削減
- リージョンデコード: ズーム時は可視領域のみデコード

## 主要パッケージ（想定）

- `cached_network_image`: ネットワーク画像のキャッシュ付きロード
- `smb_connect`: SMB 1.0/2.0/2.1 ファイル共有アクセス
- `flutter_blurhash`: BlurHashプレースホルダー表示
- Google Drive: `googleapis` or `googledrivehandler`
- OneDrive: Microsoft Graph REST API を直接呼び出し（`@microsoft.graph.downloadUrl` 経由でRange Request）
