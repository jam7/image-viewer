# 002: 動画再生に SMB→HTTP プロキシ方式を採用

## Status

Accepted

## Context

SMB 上の動画ファイルを再生する必要がある。media_kit (libmpv / FFmpeg) は HTTP/ファイルパスからの再生に対応するが、SMB プロトコルを直接扱えない。

## Alternatives

### 全体ダウンロード → ローカル再生

- 動画全体を L2 にダウンロードしてからローカルファイルとして再生
- **問題**: 数百 MB〜数 GB の動画で初期待ち時間が長すぎる

### SMB → ローカル HTTP プロキシ → media_kit

- localhost に HTTP サーバーを立て、media_kit からの HTTP リクエストを SMB の Range Read に変換
- ストリーミング再生が可能

### dart_smb2 に直接 media_kit 用の I/O を実装

- media_kit のカスタムプロトコルハンドラを実装
- **問題**: media_kit (libmpv) のカスタムプロトコル API は Dart から直接使えない

## Decision

SMB → localhost HTTP プロキシ方式を採用 (`SmbProxyServer`)。

## Consequences

- **Good**: ストリーミング再生でき、初期待ち時間がない
- **Good**: Range Request 対応でシーク可能
- **Good**: media_kit 側の変更不要。標準の HTTP 再生パスを使える
- **Bad**: プロキシサーバーの管理が必要 (起動・停止・セッション管理)
- **Mitigation**: ランダムポート + ワンタイムトークンでセキュリティ確保。`127.0.0.1` バインドで外部からアクセス不可
- **Mitigation**: SMB 接続断時は 1 回リトライ。セッション `cancelled` フラグで不要なストリーミングを中断
