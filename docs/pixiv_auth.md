# Pixiv 認証アーキテクチャ

## 概要

Pixiv API は Cookie 認証。WebView でユーザーがログインし、その Cookie を使って API を呼ぶ。

## WebView 構成

```
┌─────────────────────┐    ┌─────────────────────┐
│  ログイン用 WebView   │    │   API用 WebView      │
│  (PixivLoginScreen)  │    │  (PixivWebClient)    │
│                     │    │                     │
│  ユーザーがログイン   │    │  非表示・バックグラウンド│
│  操作する画面       │    │  fetch() でAPI呼び出し │
└─────────┬───────────┘    └─────────┬───────────┘
          │                          │
          └──── Cookie 共有 ─────────┘
            (WebView2 ユーザーデータ /
             WKWebView サンドボックス)
```

- ログイン用と API 用は別の WebView だが、Cookie ストアを共有
- Windows: 両方 `webview_windows`（WebView2）。同一ユーザーデータフォルダで Cookie 共有
- iOS: 両方 `webview_flutter`（WKWebView）。同一 WKWebsiteDataStore で Cookie 共有
- **重要**: `webview_flutter` は Windows 非対応。Windows は必ず `webview_windows`

## ページロード完了の検出

3秒待ちなどの固定遅延は使わない。必ずイベントで完了を検出する:

- Windows (`webview_windows`): `controller.loadingState` ストリームで `LoadingState.navigationCompleted` を待つ
- iOS (`webview_flutter`): `NavigationDelegate.onPageFinished` コールバック
- タイムアウト: 10秒。超えたらログ出力して続行

## 認証フロー

### 統一フロー（Cookie 有効/無効で分岐しない）

```
ユーザーが Pixiv タップ
  → registry.resolve("pixiv:default")
    → _handlePixivLogin(context)
      → await _webClient.initialize()
        → API WebView コントローラー作成のみ（ページロードしない）
      → ログイン画面を push（accounts.pixiv.net/login をロード）
        → Cookie 有効: pixiv が www.pixiv.net に即リダイレクト → pop(true)
        → Cookie 無効: ユーザーがログイン → www.pixiv.net 到達 → pop(true)
      → await _webClient.loadPixivPage()
        → API WebView で pixiv.net をロード（Cookie は共有済み）
        → ページロード完了を検出（Windows: navigationCompleted, iOS: onPageFinished）
      → return PixivApiClient ✓
```

ログイン確認は**ログイン用 WebView**が担う。API 用 WebView は認証に関わらない。
ログイン画面が Cookie 有効/無効の両方を処理する（有効なら即リダイレクトで一瞬）。
API 用 WebView のページロードはログイン確認後に1回だけ。

## API WebView の並行アクセス禁止

`fetchJson` は WebView 上で JavaScript の `fetch()` を実行し、結果を
`window['_pixiv_result_N']` に格納してポーリングで取得する。

同じ WebView で複数の fetchJson や checkLoginStatus が並行して走ると:
- ページ遷移で `window` オブジェクトが消える
- JavaScript 実行が干渉してタイムアウトする

したがって:
- `onLoginSuccess` 内で `waitForUserId` を呼ばない（fetchJson と干渉）
- バックグラウンドでの checkLoginStatus とギャラリーの API 呼び出しを同時に走らせない

## ソースの取得経路

すべての Pixiv アクセスは `SourceRegistry.resolve()` を経由する。
直接 `PixivSource()` を new しない。registry がログイン確認のゲートキーパー。

```
HomeScreen._openPixiv()     → registry.resolve("pixiv:default")
FavoritesTab._onItemTap()   → registry.resolve(entry.sourceKey)
ViewerScreen._loadFullImage() → registry.resolve(image.sourceKey)
```

## PixivSource のライフサイクル

- `PixivApiClient`（WebView ラッパー）: アプリに1つ、全画面で共有
- `PixivSource`（API + ページネーション状態）: 画面ごとに新規作成
  - おすすめ一覧用、検索結果用、作者一覧用がそれぞれ独立
  - ファイルディスクリプタのように「読み進め位置」を持つ

## ログイン成功の判定

- `accounts.pixiv.net` の別ページ（reCAPTCHA、追加認証）ではまだ完了でない
- `www.pixiv.net` に URL が到達した時点で完了
- ユーザーID は PixivLoginScreen._extractUserIdAsync() でログインページの HTML から取得
