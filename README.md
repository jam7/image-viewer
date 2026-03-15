# このプロジェクトについて

画像を表示するクロスプラットフォームアプリケーション。

## 目的

データをローカルに大量に保存せず、リモートの画像を気楽に流し読みできる環境を目指す。
過剰な高速化はしない。

## 対象OS

- iOS
- Android
- Windows

## フレームワーク

**Flutter** を採用。

選定理由:
- iOS/Android/Windowsの3プラットフォーム全てで最も成熟している
- Impellerレンダリングエンジンによる安定した描画性能（画像重視アプリに適する）
- `cached_network_image`, `smb_connect` 等の画像・ネットワーク系パッケージが充実
- コミュニティ最大、pub.devに豊富なパッケージ

## 対象サーバー

### 画像関係のサービス

- www.pixiv.net
- www.dmm.co.jp
- dlsite.com

### ネットワークプロトコル

| プロトコル | 方式 | 備考 |
|---|---|---|
| HTTP/HTTPS | 標準対応 | Range Request による部分ダウンロード対応 |
| SMB2 | `smb_connect` パッケージ (SMB 1.0/2.0/2.1) | LAN/VPN環境が必要 |

### クラウドストレージ

| サービス | 方式 | 備考 |
|---|---|---|
| Google Drive | OAuth 2.0 + Drive API v3 | 部分ダウンロード対応。APIクォータ制限あり |
| OneDrive | OAuth 2.0 + Microsoft Graph API | 部分ダウンロード対応（`@microsoft.graph.downloadUrl` 経由） |
| iCloud Drive | NSFileManager / icloud_storage | iOS/macOS限定。Apple プラットフォームのみ対応 |
