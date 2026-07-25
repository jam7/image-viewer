# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 文章規約
- 日本語の文章中でも括弧は半角 `()` を使う。全角 `（）` は使わない。

## プロジェクト概要

Flutter製のクロスプラットフォーム画像ビューアアプリ (iOS/iPad/Android/Windows)。
リモートサーバーから画像をストリーミング表示し、ローカルキャッシュを最小限に抑える。

## コーディングルール

### 並行実行の安全性 (必須)

- **インスタンス変数で非同期メソッド間の状態を共有しない**。複数の async 呼び出しが並行実行される場合、インスタンス変数は競合する。戻り値やレコード型で結果を返すこと
- サムネイルダウンロード等のバッチ処理は並行実行される前提で設計する
- 共有リソース (ファイル、DB) へのアクセスは排他制御する (`_isFlushing` パターン等)

### エラーハンドリング (必須)

- **アプリ・ライブラリ共通**: `package:logging` を使用。`print` は使わない (出力先は `main.dart` のハンドラで設定)
- **アプリ (lib/ 以下) **: catch ブロックでは必ず `_log.warning('message', e, st)` でログ出力する。`catch (_)` で握りつぶさない。画面に表示するエラーとログ出力の両方を行う
- **ライブラリ (dart_smb2/ 等) **: 例外を throw/rethrow で呼び出し元に返す。フォールバック処理で catch する場合は具体的な型 (`on FormatException` 等) でキャッチし、`catch (_)` で握りつぶさない
- **dart_smb2 のログレベル**: `main.dart` で設定。接続・認証など頻度の低いログ (`Smb2Client`) は INFO 許可。大量に出る I/O ログ (`Smb2Multiplexer`, `Smb2FileReader`, `Smb2Tree`) は WARNING 以上に制限
- **ログレベル変更時の原則**: ライブラリのログを抑制する場合、必要なログまで抑制しないか確認する。ワークアラウンド (warning に昇格、アプリ層で代替出力) ではなく、ログレベル設定自体を見直す

### バグ調査の進め方 (必須)

- クラッシュやバグが報告されたら、**まずログを読んで根本原因を特定する**。ガードやフォールバックで隠してはいけない
- ログから原因が特定できない場合は、**該当箇所にログを追加して再実行し、原因を絞り込む**。推測で修正しない
- 原因が特定できてから修正する。修正が正しいことをログや再現手順で確認する

### git push の禁止 (必須)

- **`git push` はユーザーから「push して」と明示的に指示されるまで絶対にしない**
- commit は自由にしてよいが、push は指示があるまで行わない
- commit コマンドに `&& git push` を含めない
- push 済みだと amend ができず force push が必要になる。履歴整理の妨げになる

### 実装時の説明責任

- 新機能や設計変更時は、方針と考え方を説明してから実装する
- pull した変更をレビューし、上記ルールに違反するコードがあれば指摘・修正する

## ドキュメント・記録の配置

ドキュメントや記録は性質で 3 つに分けて置く。「現在の正」「時系列の記録」「生きた
やることリスト」を混ぜない。

| 種類 | 性質 | 置き場 | 公開 |
|---|---|---|---|
| 要件・仕様・設計 | 現在の正 (常に最新に保つ) | `docs/<feature>/` | 公開 |
| 調査メモ・fix-loop 台帳・review-log | 時系列の記録 (追記のみ、消さない) | `notes/` | **非公開** |
| やることリスト | 生きたリスト (完了したら消し込む) | `notes/TODO.md` | **非公開** |

- `notes/` の内訳: やることリストは `notes/TODO.md`、fix-loop 台帳は
  `notes/fix-sessions/YYYYMMDD-<topic>.md`、調査・レビューの全文記録は
  `notes/reviews/YYYYMMDD-<topic>.md`、繰り返し出る指摘の台帳は `notes/review-log.md`
- dart_smb2 の設計記録はサブモジュール内 `dart_smb2/docs/reviews/` に置く (別リポジトリ)

### notes/ は非公開の別リポジトリ (必須)

このリポジトリは GitHub 上で public。`notes/` は開発中の記録 (実機ログの抜粋、実際の
ファイルパス、試行錯誤の履歴) を貯める場所で、公開価値がない一方で実データが混入
しやすい。そのため `notes/` は**この repo の管理外**にしてある:

- `.gitignore` で `notes/` を除外済み。親 repo からは見えない (`git status` にも出ない)
- `notes/` 自身が独立した git repo (非公開)。ネスト構成なので submodule にはしない
  (submodule にすると `.gitmodules` に非公開 URL が載り、他人の clone が壊れる)
- **notes/ の変更は notes/ 内で commit する**。親 repo の commit には含まれない

この分離の帰結として、以下を守る:

- **公開して困る実データ (実ファイルパス、実機ログ、購入済み作品の情報) は
  `notes/` にだけ書く**。`docs/` や commit message には書かない
- 調査で得た**結論**は `docs/` か ADR に昇格させる。notes は非公開なので、
  結論を notes だけに置くと公開側から経緯が追えなくなる
- `notes/` から `docs/` や `lib/` を参照するときはリンクにせずパス文字列で書く
  (別 repo なので相対リンクが解決しない)

### レビュー結果の行き先

レビューで出た指摘は内容ごとに 4 つに振り分ける:

| 内容 | 行き先 |
|---|---|
| PR に対するレビュー | PR コメント (repo 外、変更に紐づく) |
| ローカルレビューの全文記録 | `notes/reviews/YYYYMMDD-<topic>.md` |
| 今直さない指摘 | `notes/TODO.md` に 1 行 |
| 繰り返し出る指摘パターン | `notes/review-log.md` → 同じ指摘が 3 回出たら checklist に昇格 |

### TODO 項目の進め方

TODO の項目は変更の性質で進め方とドキュメント更新が変わる:

| TODO 項目の種類 | 進め方 | docs に残すもの |
|---|---|---|
| 挙動を変えない小さな修正 (ガード節化、関数抽出、命名) | fix-loop だけ | なし (台帳が `notes/fix-sessions/` に残れば十分) |
| 設計判断を伴う構造変更 (2 画面の統合、基底クラス化など) | spec-dev を軽量適用 (フェーズ 0/1 はほぼ省略し design.md + ADR が中心) | `design.md` (なぜこの分割にしたか = ADR) |
| 挙動を変える修正 (仕様の誤り・不足が根本原因) | rework → spec-dev (上流文書を先に直してから) | requirements/spec/design の該当箇所を更新 |

## 開発コマンド

```bash
flutter analyze          # 静的解析
flutter test             # 全テスト実行
flutter test test/widget_test.dart  # 単一テスト実行
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8 # flutterの出力のパースをutf8に
flutter run -d windows 2>&1 | Tee-Object -FilePath "C:\Users\jam\flutter_log.txt"  # Windows向け (PowerShell、ログは C:\Users\jam\flutter_log.txt)
flutter run -d <iPad ID> # iOS/iPad向け (flutter devices でID確認)
flutter run -d chrome    # Web向け (デバッグ用)
```

iOS/iPad のセットアップは [docs/ios_setup.md](docs/ios_setup.md) を参照。

## コード構成

[docs/code_structure.md](docs/code_structure.md) を参照。

## アーキテクチャ

詳細は `docs/` 以下のドキュメントを参照。

| ドキュメント | 内容 |
|---|---|
| [docs/thumbnail_architecture.md](docs/thumbnail_architecture.md) | ThumbnailLoader、バッチ処理、動画サムネイル、プロキシ |
| [docs/viewer_architecture.md](docs/viewer_architecture.md) | ViewerScreen、VideoPlayerScreen、プリフェッチ、キャッシュ、PDF/ZIP 処理 |
| [docs/pixiv_auth.md](docs/pixiv_auth.md) | Pixiv 認証フロー (WebView 2台構成) |
| [docs/pixiv_connection.md](docs/pixiv_connection.md) | Pixiv 接続仕様 (API エンドポイント、fetch 機構、データモデル、PixivSource) |
| [docs/adr/](docs/adr/README.md) | Architecture Decision Records (設計判断の記録) |

### キャッシュ概要

| 層 | 保存先 | 内容 | 排出 |
|---|---|---|---|
| L1 | メモリ | デコード済み画像 〜10枚 | LRU自動 |
| L2 | ディスク | 圧縮画像 500MB〜5GB (設定可) | LRU自動 |
| L3 | ディスク | ユーザーが明示的にDLした作品 | 手動トグル |
| お気に入り | JSON | URL+メタデータのみ (画像なし) | 手動トグル |

CacheManager が L1→L2→L3→ネットワークの順に検索。キー命名: `thumb:<id>` (サムネイル)、`full:<id>` (表示用データ)。

### Pixiv 認証

- WebView 2台構成 (ログイン用 + API 用)、Cookie ストア共有
- `webview_flutter` (iOS/Android)、`webview_windows` (Windows)
- 詳細は [docs/pixiv_auth.md](docs/pixiv_auth.md)

### SMB

- `dart_smb2` (自作) で SMB 2.0/2.1 対応
- ZIP: `archive_reader` (自作) で Range Read ベースの個別エントリ展開
- PDF: `pdfrx` (PDFium) で `PdfDocument.openFile` → ページレンダリング
- 動画: `media_kit` + `SmbProxyServer` (localhost HTTP プロキシ)

### 認証情報の保存場所

| プラットフォーム | Pixiv セッション | SMB パスワード |
|---|---|---|
| Windows | WebView2 ユーザーデータフォルダ | Credential Manager |
| iOS/macOS | WKWebView サンドボックス | Keychain |
| Android | WebView サンドボックス | EncryptedSharedPreferences |

## 主要パッケージ

- `webview_flutter`: iOS/Android 用 WebView (ログイン + API)
- `webview_windows`: Windows 用 WebView2 (ログイン + API)
- `dart_smb2`: SMB 2.0/2.1 クライアント (自作、dart_smb2/ ディレクトリ)
- `archive_reader`: Range Read ベースの ZIP リーダー (自作、packages/archive_reader/)
- `pdfrx`: PDF ページレンダリング (PDFium ベース、upstream 版)
- `media_kit` / `media_kit_video`: 動画再生 (libmpv / FFmpeg ベース、ほぼ全フォーマット対応)
- `flutter_secure_storage`: パスワード安全保管 (Keychain/Credential Manager)
- `dio`: HTTP通信 (画像ダウンロード等)
- `path_provider`: アプリ固有ディレクトリ取得
- `crypto`: ハッシュ計算
