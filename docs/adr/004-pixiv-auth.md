# 004: Pixiv 認証に WebView 2台構成を採用

## Status

Accepted

## Context

Pixiv は公式 API を公開しておらず、Web API を Cookie 認証で呼ぶ必要がある。ログインフローと API 呼び出しの両方を実現する必要がある。

## Alternatives

### OAuth / トークンベース認証

- Pixiv は公式 OAuth を提供していない
- 非公式の OAuth エンドポイントは不安定で廃止リスクが高い

### WebView 1台でログイン + API

- ログインページ表示と API 呼び出しを同一 WebView で行う
- **問題**: API 呼び出し中にページ遷移が発生し、ログイン状態の管理が複雑

### WebView 2台構成

- ログイン用 WebView (PixivLoginScreen): ユーザーがログインページで認証
- API 用 WebView (PixivWebClient): Cookie を共有し、JavaScript で API を呼び出し

## Decision

WebView 2台構成を採用。Cookie ストアを共有し、ログイン用でログインすれば API 用も認証済みになる。

## Consequences

- **Good**: ログインフローと API 呼び出しが分離され、それぞれ独立に管理可能
- **Good**: パスワードをアプリ側で一切保存しない。WebView のログインページでユーザーが入力する
- **Good**: Cookie はブラウザと同等のセキュリティレベル (OS サンドボックス保護)
- **Bad**: WebView 2台分のリソース消費
- **Bad**: CSRF トークンをログイン WebView の HTML から抽出する必要がある (エスケープ済み JSON のパース)
- **Note**: 認証フローの詳細は [docs/pixiv_auth.md](../pixiv_auth.md) を参照
