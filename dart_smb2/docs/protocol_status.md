# SMB2 Protocol Implementation Status

dart_smb2 は読み取り専用の SMB 2.0/2.1 クライアントライブラリ。
Negotiate → 認証 → TreeConnect → QueryDirectory → Create → Read のパスが完成しており、多重化・先読みパイプラインで読み取り性能を最適化している。

## 実装済み

### Negotiate

- ダイアレクト: SMB 2.0.2 (0x0202), 2.1 (0x0210), 3.0 (0x0300)
- サーバーの capabilities、max read/write サイズ、GUID をパース
- 実用上の読み取りサイズは 1MB に制限 (サーバーがより大きい値を提示しても)

### 認証 (NTLMv2)

- NTLMSSP + SPNEGO ラッピング
- 3メッセージハンドシェイク (Type1 → Type2 → Type3)
- NTLMv2 レスポンス (HMAC-MD5)
- AV ペア解析、タイムスタンプによるリプレイ保護
- セッションベースキーの算出コードあり (署名用、現在未使用)

### Session Management

- Session Setup (SPNEGO 2メッセージ)
- Logoff (切断時に送信)
- SessionId による状態管理

### Tree Operations

- Tree Connect / Disconnect
- 共有タイプ検出: DISK (0x01), PIPE (0x02), PRINT (0x03)

### File Operations

| コマンド | 状態 | 備考 |
|---|---|---|
| Create | 実装済み | ファイル・ディレクトリのオープン (読み取りアクセス) |
| Close | 実装済み | |
| Read | 実装済み | マルチブロック、先読みパイプライン、最大 1MB/ブロック |

### Directory Operations

- QueryDirectory: FileBothDirectoryInformation (0x03), FileIdBothDirectoryInformation (0x25)
- ファイル属性、タイムスタンプ (作成/アクセス/書き込み/変更)、サイズをパース
- `.` / `..` エントリの処理
- STATUS_NO_MORE_FILES までページネーション

### メッセージ多重化

- MessageId ベースの並行リクエスト (最大 32 本、設定可能)
- 専用受信ループで MessageId によるディスパッチ
- FIFO 送信ロック (ソケット書き込みの直列化)
- In-flight リクエストの追跡とキャンセル

### クレジット管理 (部分的)

- サーバー付与クレジットの追跡
- 大容量読み取り時のクレジットチャージ計算: `ceil(length / 65536)`
- 同時リクエスト上限 32 本によるシンプルな制御

### プロトコル基盤

- SMB2 ヘッダ: 64バイト完全エンコード/デコード
- 全 19 コマンドの定数定義
- 主要な NT ステータスコード定義
- NetBIOS フレーミング (4バイトセッションヘッダ、Keep-alive)

## 未実装

### 書き込み系

| コマンド | 備考 |
|---|---|
| Write | 読み取り専用アプリのため不要 |
| Flush | 同上 |
| Lock | 同上 |
| SetInfo | ファイル属性の変更 |

### セキュリティ

| 機能 | 備考 |
|---|---|
| メッセージ署名 | ヘッダに署名フィールドはあるが未計算。セッションキー算出コードは存在 |
| SMB3 暗号化 | AES-CCM/GCM |
| Kerberos 認証 | NTLMv2 のみ対応。Active Directory 環境では Kerberos が望ましい |

### 高度なプロトコル機能

| 機能 | 備考 |
|---|---|
| Named Pipes / RPC | IPC$ 接続、SRVSVC (NetShareEnumAll = listShares) 等。共有名の自動列挙に必要 |
| Compound Requests | 複数リクエストを1パケットにまとめる。Create+Read 等のラウンドトリップ削減 |
| ChangeNotify | ファイル変更の通知 |
| QueryInfo | ファイル情報の個別取得 (Create/QueryDirectory のレスポンスからは取得済み) |
| Ioctl | デバイス制御。FSCTL_DFS_GET_REFERRALS 等 |
| Cancel / Echo | リクエストキャンセル、接続確認 |
| OplockBreak / Leases | ファイルロック・リース管理 |
| DFS | 分散ファイルシステム参照 |
| Multichannel | 複数 TCP 接続による帯域集約 (SMB 3.0) |
| Reparse Points | シンボリックリンク、ジャンクション |

## 未実装機能の影響

| ユーザーシナリオ | 必要な未実装機能 |
|---|---|
| 共有一覧の自動列挙 | Named Pipes + SRVSVC RPC |
| 署名必須のサーバーへの接続 | メッセージ署名 |
| Active Directory 環境 | Kerberos 認証 |
| ファイルの書き込み・削除 | Write, SetInfo |
| シンボリックリンクのフォロー | Reparse Points, Ioctl |
| VPN 越しの安全な接続 | SMB3 暗号化 |
