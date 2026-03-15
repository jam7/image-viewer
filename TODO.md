# TODO

## ビューア
- [ ] 高速スクロール時はサムネイル表示、停止後にフル解像度に差し替え
  - `/ajax/illust/{id}/pages` の `thumb_mini` URLを利用
  - スクロールバーをドラッグ中はサムネイルのみ、離したらフル画像ロード
- [ ] ズーム時のリージョンデコード（可視領域のみ）

## ネットワーク
- [ ] Range Request対応（ZIPファイル内の個別画像取得に必要）
- [ ] ZIPファイル対応（Pixiv ugoira等）

## プリフェッチ
- [ ] スライディングウィンドウ方式のプリフェッチ実装

## プロバイダー
- [ ] DMM対応
- [ ] iCloud Drive対応（iOS/macOS限定）
- [ ] その他プロバイダー（HTTP/SMB/Google Drive/OneDrive）
