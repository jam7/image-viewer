# 001: PDF レンダラーに pdfrx を採用

## Status

Accepted

## Context

SMB 上の PDF ファイルをページ単位で表示する必要がある。Flutter で PDF をレンダリングするパッケージの選定。

## Alternatives

### printing パッケージ

- `Printing.raster()` でページをラスタライズ
- **問題**: プラットフォームチャネル経由で UI スレッドをブロックする。大容量 PDF でページめくり中に操作不能になる
- ESC でキャンセルできない

### pdfrx パッケージ (PDFium ベース)

- FFI で PDFium を直接呼び出し
- 非同期レンダリング (UI ブロックなし)
- `PdfDocument.openFile` で `FPDF_LoadDocument` を使用 (ファイルを直接読み、メモリに全体を載せない)

## Decision

pdfrx (upstream 版)を採用。

## Consequences

- **Good**: UI がブロックされない。大容量 PDF でもスムーズにページめくり可能
- **Good**: `openFile` によりメモリ消費を抑えられる (PDF 全体をメモリに載せない)
- **Good**: `PdfDocument` を1つキャッシュして再利用することで、同一 PDF のページめくりが高速
- **Bad**: PDFium のレンダリングはシリアル処理。約 500ms/ページで先読み枚数を 2 に制限する必要がある
- **Bad**: PDF 全体を事前に L2 にダウンロードする必要がある (Range Read でのページ単位取得もopenCustomeで可能そうだったが試してない)
