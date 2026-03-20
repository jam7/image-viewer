# Pixiv 認証アーキテクチャ

## Pixiv が必要とする処理

Pixiv の API（`/ajax/...`）は Cookie ベースの認証が必要。Cookie がない、または期限切れの場合は `{"error":true}` が返る。

認証の流れ:
1. ユーザーが `accounts.pixiv.net/login` でログイン
2. ブラウザ（WebView）に Cookie が保存される
3. 以降の API 呼び出しはその Cookie を使う

Cookie の寿命はブラウザセッションに依存。アプリを閉じても WebView のデータフォルダに永続化される（Windows: `%LOCALAPPDATA%\flutter_webview_windows\image_viewer`）。

## アーキテクチャの変遷

### 第1世代: 強制ログイン（アプリ起動時）

```
アプリ起動 → ログイン画面（必須） → ログイン成功 → ギャラリー表示
```

- `app.dart` が `_isLoggedIn` フラグで管理
- Cookie があってもログイン画面を表示（ページが `www.pixiv.net` にリダイレクトされれば即完了）
- 問題: **Pixiv 以外のソース（SMB）を使うだけなのにログインを強制**

### 第2世代: 遅延ログイン + 共有 PixivSource（ホーム画面導入時）

```
アプリ起動 → ホーム画面
  Pixiv タップ → ログイン済み？ → Yes → ギャラリー
                                → No  → ログイン画面 → ギャラリー
```

- `SourceRegistry` が遅延ログインを管理
- `app.dart` が1つの `PixivSource` を作成し、全画面で共有
- `_handlePixivLogin` コールバックで Cookie 確認 → 未ログインならログイン画面を push
- 問題: **`PixivSource` を共有するため、複数の GalleryScreen でページネーション状態（`_nextOffset`）が競合**

### 第3世代: 遅延ログイン + 画面ごと PixivSource（現在）

```
アプリ起動 → ホーム画面
  Pixiv タップ → registry.resolve("pixiv:default") → ログイン確認 → 新しい PixivSource 作成 → ギャラリー
  作者タップ  → registry.resolve("pixiv:default") → 新しい PixivSource 作成 → 作者ギャラリー
```

- `SourceRegistry` は `PixivApiClient`（認証/WebView 共有）を保持
- `resolve()` のたびに新しい `PixivSource` を返す（ファイルディスクリプタのように独立した読み進め状態）
- `PixivApiClient` は共有（WebView は1つ、Cookie も共有）

## 現在の問題（未修正）

### 問題1: `_openPixiv` が registry を経由していない

`HomeScreen._openPixiv()` が `PixivSource(client: widget.pixivApiClient)` で直接作成しており、`registry.resolve()` を通っていない。そのため `_handlePixivLogin`（ログイン確認 + ログイン画面表示）が呼ばれない。

**原因**: 第3世代への移行時に `app.dart` が `_ensureApiClient()` を `build()` 内で呼び、`HomeScreen` に `pixivApiClient` を直接渡す設計にした。これにより `HomeScreen` が registry を迂回して `PixivSource` を作れるようになってしまった。

**修正方針**: `HomeScreen` は `pixivApiClient` を受け取らない。Pixiv を使う全ての場面で `registry.resolve()` を経由する。registry が唯一の Pixiv ソース取得経路とする（ゲートキーパー）。

### 問題2: `SourceRegistry._resolvePixiv` がログイン状態を確認しない

`_resolvePixiv` は `_pixivApiClient != null` なら即座に `PixivSource` を返す。しかし `_pixivApiClient` が非 null でも Cookie が無効（削除された、期限切れ）の場合がある。

**原因**: `_ensureApiClient()` が `build()` で毎回呼ばれるため `_pixivApiClient` は常に非 null。ログイン状態と `_pixivApiClient` の存在が分離している。

**修正方針**: `_resolvePixiv` 内で `checkLoginStatus()` を呼び、Cookie が無効ならログイン画面を表示する。もしくは `_pixivApiClient` を「ログイン確認済み」フラグと紐付ける。

### 問題3: ログイン成功判定が不正確だった

`PixivLoginScreen._onUrlChanged` が `accounts.pixiv.net/login` から離れただけでログイン成功と判定していた。Pixiv が追加認証（reCAPTCHA 等）を要求した場合、認証途中でログイン成功と誤判定。

**修正済み**: `www.pixiv.net` に到達したかどうかで判定するように変更（commit 8d9b856）。

## コンポーネント関係図

```
app.dart (_AppRootState)
  ├── PixivWebClient          : WebView 管理、Cookie 保持、fetchJson
  ├── PixivApiClient          : Pixiv Web API ラッパー（WebClient を使用）
  ├── SourceRegistry          : sourceKey → ImageSourceProvider の解決
  │     ├── _pixivApiClient   : 共有（認証情報）
  │     ├── onPixivLoginRequired : ログイン画面表示コールバック
  │     └── resolve("pixiv:*") → new PixivSource(client) を毎回返す
  └── HomeScreen
        ├── Pixiv タップ → registry.resolve() → GalleryScreen
        ├── お気に入り  → registry.resolve() → ViewerScreen
        └── SMB タップ  → registry.resolve() → SmbGalleryScreen
```

## 守るべき原則

1. **Pixiv ソースの取得は必ず `registry.resolve()` を経由する**。直接 `PixivSource()` を new しない
2. **`PixivApiClient` の存在 ≠ ログイン済み**。Cookie の有効性は `checkLoginStatus()` で確認する
3. **`PixivSource` は画面ごとに新規作成**。ページネーション状態の共有を避ける
4. **ログイン画面は `www.pixiv.net` 到達で完了判定**。中間ページ（追加認証等）は無視
