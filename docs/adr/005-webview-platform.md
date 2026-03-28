# 005: WebView のプラットフォーム別実装

## Status

Accepted

## Context

Pixiv 認証に WebView を使用するが、Flutter の WebView パッケージはプラットフォームごとに対応状況が異なる。

## Alternatives

### webview_flutter のみ

- Flutter 公式パッケージ
- iOS / Android に対応
- **問題**: Windows に非対応

### webview_windows のみ

- WebView2 (Chromium ベース) ラッパー
- Windows に対応
- **問題**: iOS / Android に非対応

### webview_flutter + webview_windows

- プラットフォーム判定で切り替え
- iOS/Android: `webview_flutter`
- Windows: `webview_windows`

## Decision

`webview_flutter` (iOS/Android) + `webview_windows` (Windows) を組み合わせて使用。

`PixivLoginScreen` と `PixivWebClient` でプラットフォーム判定し、適切な WebView 実装を選択。

## Consequences

- **Good**: 全ターゲットプラットフォーム (iOS/Android/Windows) をカバー
- **Bad**: WebView の API が異なるため、ログイン画面と API クライアントの両方にプラットフォーム分岐が必要
- **Bad**: Cookie 管理の API も異なり、共有ロジックの抽象化が困難
- **Mitigation**: プラットフォーム分岐は `PixivLoginScreen` と `PixivWebClient` に閉じ込め、上位の `PixivApiClient` / `PixivSource` はプラットフォーム非依存
