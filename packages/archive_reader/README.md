# archive_reader

Range Read ベースのアーカイブリーダー。ファイル全体をダウンロードせずに、個別エントリを取得できる。

## 目的

SMB や HTTP の Range Request を使って、アーカイブ内の任意のファイルを個別に取得する。
数百 MB の ZIP でも、最初のページだけなら数秒で表示できる。

## 対応フォーマット

- ZIP（Store / Deflate）
- RAR（将来対応）

## 設計方針

### RangeReader による抽象化

ファイルの読み込みを `RangeReader` コールバックで抽象化する。
SMB の `readRange` でも HTTP の `Range` ヘッダーでも同じインターフェースで使える。

```dart
typedef RangeReader = Future<Uint8List> Function(int offset, int length);
```

### 遅延取得

ZIP のセントラルディレクトリ（末尾にある）だけを読んでファイル一覧を取得し、
必要なファイルだけを Range Read + 展開する。

```
1. EOCD (End of Central Directory) を読む ← ZIP 末尾の数十バイト
2. セントラルディレクトリを読む ← ファイル名・オフセット・サイズの一覧
3. 必要なファイルだけ Range Read ← 圧縮データのみ取得
4. Store ならそのまま、Deflate なら展開
```

### 利用シナリオ

**サムネイル取得**:
- セントラルディレクトリでファイル名一覧を取得
- 自然順ソートで最初の画像を特定
- その画像だけ Range Read + 展開

**ビューアでの即時表示**:
- ファイル一覧から resolvePages を構築（ZIP 全体のダウンロード不要）
- 最初のページだけ Range Read → 即表示
- 前方数ページをバックグラウンドで先読み
- 残りはアイドル時にゆっくり取得

## API

```dart
abstract class ArchiveReader {
  /// ファイル一覧を取得（セントラルディレクトリ等を読む）
  Future<List<ArchiveEntry>> listEntries();

  /// 指定エントリのデータを取得（Range Read + 展開）
  Future<Uint8List> readEntry(ArchiveEntry entry);
}

class ZipReader implements ArchiveReader {
  final RangeReader readRange;
  final int fileSize;

  ZipReader({required this.readRange, required this.fileSize});
}

class ArchiveEntry {
  final String name;
  final int compressedSize;
  final int uncompressedSize;
  final int offset;
  final int compressionMethod; // 0=Store, 8=Deflate
}
```
