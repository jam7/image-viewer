# TODO

## Pixiv ログイン
- [x] ログイン→ギャラリー遷移中のホーム画面露出: ログイン画面 pop 後、API WebView の pixiv.net ロード完了までホーム画面が見えてしまう（Cookie 有効時も同様）。ログイン画面が API WebView のロードも完了してから pop する方式に変更すべき

## ナビゲーション
- [x] GalleryScreen のナビゲーション再設計: 現在は作者一覧・検索結果が同じ画面内の状態変更なので戻れない。showUserWorks や検索で新しい GalleryScreen を push し、Navigator の履歴として残す。deactivate で画像データを解放すればメモリは問題ない
- [x] GalleryScreen のタブごとに独立した PixivSource を持つ（タブ切り替えで読み進め位置が消える問題の解決）
- [ ] ブラウザ風の履歴ジャンプ: 戻るボタン長押しで画面履歴一覧を表示し、popUntil で数段飛ばして戻れるようにする。各画面に RouteSettings(name) を付けて自前の履歴リストを管理

## ビューア
- [ ] 高速スクロール時はサムネイル表示、停止後にフル解像度に差し替え
  - `/ajax/illust/{id}/pages` の `thumb_mini` URLを利用
  - スクロールバーをドラッグ中はサムネイルのみ、離したらフル画像ロード
- [ ] ズーム時のリージョンデコード（可視領域のみ）

## dart_smb2
- [x] ライブラリ内の print をロギング機構に置き換え（package:logging）
- [ ] listShares() 実装 → 接続設定UIで共有フォルダ一覧から選択できるようにする（共有名の手入力を不要にする）
- [x] SMB 再接続ロジック: 長時間アイドル後にサーバー側でセッションが切れた場合の自動再接続。Smb2Client.isConnected で検出し、SmbSource._connect() で透過的に再接続

## SMB ZIP 対応
- [x] Phase 1: ZIP ファイルの基本対応（ダウンロード → 展開 → L2 キャッシュ → ビューア表示）
- [x] Phase 2: ZIP サムネイル・ページ取得を Range Read 化（archive_reader パッケージで ZIP 全体をダウンロードせず個別エントリを取得）
- ~~Phase 3: ZIP 間の先読み~~ → Range Read 化で resolvePages が十分高速になり不要

## PDF 対応
- [x] PDF ページレンダリング（pdfrx / PDFium）
- [x] pdfrx の FPDF_LoadCustomDocument デッドロック修正（fork: packages/pdfrx）
- [x] PDF バイトの L2 キャッシュ（再オープン時に再DL不要）
- [x] レンダリング済み PNG のビューア離脱時 L2 削除（2倍消費回避）
- [x] openFile 化: PDF 全体をメモリに載せず L2/L3 のファイルパスから直接開く（fork 不要に）
- [x] pdfrx 本家へのバグ報告 / PR（openData で FPDF_LoadMemDocument を使うべき件）
- [x] PDF サムネイル: L2/L3 に PDF がある場合、page 0 をレンダリングしてサムネイル表示

## サムネイル
- [x] サムネイルキャッシュキー修正: thumb: キーのみ検索、full: は検索しない
- [x] サムネイルリサイズ: 全種別で長辺 600px にリサイズして thumb: に保存
- [x] ビューアから戻った時に notSupported サムネイルを自動リトライ
- [x] ZIP サムネイルの L3 問題: thumb: キーのみ検索に変更したため解決済み

## ダウンロード（L3）
- [x] 作品単位 DL（ZIP 全体 / PDF 全体 / Pixiv 全ページ）
- [x] ZIP ストリーミング DL（メモリ枯渇回避）
- [x] DL キャンセル対応（ESC / 部分ファイル削除）
- [x] DownloadStore に put/remove API 追加
- [ ] DL 済み作品の閲覧画面（L3 ブラウズ UI）
- [ ] メタデータによるグルーピング表示（作者名、ソース別、作品名等）
- [ ] DL 済み ZIP のローカル RangeReader での閲覧（SMB 不要）
- [ ] DL 済み PDF のローカル閲覧

## ネットワーク
- [ ] Range Request対応（ZIPファイル内の個別画像取得に必要）
- [ ] ZIPファイル対応（Pixiv ugoira等）

## プリフェッチ
- [ ] スライディングウィンドウ方式のプリフェッチ実装

## 認証
- [ ] iOS/iPad WKWebView でオートフィル（パスワード自動入力）を有効化

## プロバイダー
- [ ] DMM対応（API 調査済み、private submodule 構成決定済み → docs/dmm_auth.md）
- [ ] iCloud Drive対応（iOS/macOS限定）
- [ ] その他プロバイダー（HTTP/Google Drive/OneDrive）

## App Store
- [ ] Phase 1: ローカル利用時間管理 + 制限 UI
- [ ] Phase 2: StoreKit 接続（RevenueCat）、サブスクリプション課金
