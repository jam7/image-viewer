# TODO

## ナビゲーション
- [ ] ブラウザ風の履歴ジャンプ: 戻るボタン長押しで画面履歴一覧を表示し、popUntil で数段飛ばして戻れるようにする。各画面に RouteSettings(name) を付けて自前の履歴リストを管理

## ビューア
- [ ] 高速スクロール時はサムネイル表示、停止後にフル解像度に差し替え
  - `/ajax/illust/{id}/pages` の `thumb_mini` URLを利用
  - スクロールバーをドラッグ中はサムネイルのみ、離したらフル画像ロード
- [ ] ズーム時のリージョンデコード（可視領域のみ）

## パフォーマンス
- [ ] SMBダウンロード・EXIF解析をIsolateに逃がす（UIスレッドのカクつき改善）
- [ ] SMB代替としてWebDAV対応を検討（QNAPは対応済み、HTTP経由で高速化の可能性）

## dart_smb2
- [x] ライブラリ内の print をロギング機構に置き換え（package:logging）
- [ ] listShares() 実装 → 接続設定UIで共有フォルダ一覧から選択できるようにする（共有名の手入力を不要にする）

## ネットワーク
- [ ] Range Request対応（ZIPファイル内の個別画像取得に必要）
- [ ] ZIPファイル対応（Pixiv ugoira等）

## プリフェッチ
- [ ] スライディングウィンドウ方式のプリフェッチ実装

## 認証
- [ ] iOS/iPad WKWebView でオートフィル（パスワード自動入力）を有効化

## プロバイダー
- [ ] DMM対応
- [ ] iCloud Drive対応（iOS/macOS限定）
- [ ] その他プロバイダー（HTTP/SMB/Google Drive/OneDrive）
