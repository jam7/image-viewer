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

- catch ブロックでは必ず `print('[Component] error: $e\n$st')` でログ出力する。`catch (_)` で握りつぶさない
- 画面に表示するエラーとログ出力の両方を行う

### 実装時の説明責任

- 新機能や設計変更時は、方針と考え方を説明してから実装する
- pull した変更をレビューし、上記ルールに違反するコードがあれば指摘・修正する

## 開発コマンド

```bash
flutter analyze          # 静的解析
flutter test             # 全テスト実行
flutter test test/widget_test.dart  # 単一テスト実行
flutter run -d windows   # Windows向けビルド＆実行（Windows側で実行）
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
│   │   ├── http_source.dart
│   │   ├── smb_source.dart
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
│   └── prefetch/
│       └── prefetch_manager.dart      # スライディングウィンドウ制御
├── screens/                           # 画面（画面固有のウィジェットも同フォルダに置く）
│   ├── gallery/gallery_screen.dart    # サムネイル一覧
│   ├── viewer/viewer_screen.dart      # フルスクリーン画像ビューア（スワイプ/キーボード操作）
│   ├── pixiv/pixiv_login_screen.dart  # Pixivログイン（プラットフォーム別WebView）
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

### Pixiv 認証 & API（WebView 2台構成）

```
┌─────────────────────┐    ┌─────────────────────┐
│  ログイン用 WebView   │    │   API用 WebView      │
│  (pixiv_login_screen)│    │  (pixiv_web_client)  │
│                     │    │                     │
│  ユーザーがログイン   │    │  非表示・バックグラウンド│
│  操作する画面       │    │  fetch() でAPI呼び出し │
└─────────┬───────────┘    └─────────┬───────────┘
          │                          │
          └──── Cookie 共有 ─────────┘
            (WKWebsiteDataStore /
             WebView2 ユーザーデータ)
```

- 2つの WebView は Cookie ストアを共有。ログイン用でログインすれば API 用も認証済みになる
- API 用 WebView はアプリ起動時に pixiv.net を読み込み、ログイン画面と並行で準備
- ログイン用: Windows は `webview_windows`（WebView2）、iOS は `webview_flutter`（WKWebView）
- API 用: iOS は `webview_flutter`、Windows は `webview_windows`（`webview_flutter` は Windows 非対応のため）
- **重要**: `webview_flutter` は Windows をサポートしていない。Windows 向けは必ず `webview_windows` を使うこと
- ログイン成功検知: URL変化時点で即座に遷移（iOS は `onUrlChange`、Windows は `url.listen`）。ページ読み込み完了を待たない
- `fetchJson` は `initialize()` の完了を await するため、API用WebView未準備でも安全に呼べる
- ログイン画面で取得したユーザーIDは `onLoginSuccess` 経由で `PixivWebClient.userId` に設定
- PixivWebClient → PixivApiClient → PixivSource の順に抽象化

### SMB ファイルブラウズ

- `smb_connect` パッケージで SMB 1.0/2.0/2.1 対応（自動ネゴシエーション）
- 接続設定は JSON ファイルに保存（パスワード除外）
- パスワードは `flutter_secure_storage`（iOS: Keychain、Windows: Credential Manager）に保存
- ディレクトリ一覧→画像フィルタ→サムネイル/フル画像取得の流れ
- ビューアでは同一ディレクトリ内の画像を連続閲覧可能（ホイール/キー操作）
- プリロード: 現在 + 前方2枚 + 後方1枚（キャッシュヒット時はDL不要）

### 認証情報の保存場所

| プラットフォーム | Pixiv セッション | SMB パスワード |
|---|---|---|
| Windows | WebView2 ユーザーデータフォルダ（`%LOCALAPPDATA%`配下、平文SQLite、OSユーザー権限で保護） | Credential Manager |
| iOS/macOS | WKWebView サンドボックス内（アプリ間アクセス不可） | Keychain |
| Android | WebView サンドボックス内 | EncryptedSharedPreferences |

- Pixiv パスワードはアプリ側で一切保存しない。WebView のログインページでユーザーが入力する
- Pixiv の Cookie はブラウザと同等のセキュリティレベル（暗号化なし、OS権限で保護）
- SMB パスワードはプラットフォームの暗号化ストレージを使用

### ビューア操作

| 入力 | 動作 |
|---|---|
| 上スワイプ | 次ページ |
| 下スワイプ | 前ページ |
| マウスホイール | ページ送り |
| Ctrl + ホイール | ズーム |
| 矢印キー / Space | ページ送り |
| Escape | 一覧に戻る |

### ネットワーク

- HTTP/2 マルチプレクシング優先（1接続で複数ストリーム、優先度制御可能）
- HTTP/1.1 フォールバック時は同一ホストに4〜6本のコネクションプール
- 優先度キュー: 表示中画像 > 次の画像 > 先読み画像

### メモリ管理

- サブサンプリング: 画面サイズに応じて縮小デコード（メモリ大幅削減）
- RGB565フォーマット: 透過不要な画像は2バイト/ピクセルで50%削減
- リージョンデコード: ズーム時は可視領域のみデコード

## 主要パッケージ

- `webview_flutter`: iOS/Android 用 WebView（ログイン + API）
- `webview_windows`: Windows 用 WebView2（ログイン + API）
- `smb_connect`: SMB 1.0/2.0/2.1 クライアント
- `flutter_secure_storage`: パスワード安全保管（Keychain/Credential Manager）
- `dio`: HTTP通信（画像ダウンロード等）
- `path_provider`: アプリ固有ディレクトリ取得
- `crypto`: ハッシュ計算
