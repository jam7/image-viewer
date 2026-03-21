/// A single entry (file) in an archive.
class ArchiveEntry {
  /// File name including path within the archive.
  final String name;

  /// Size of the compressed data in bytes.
  final int compressedSize;

  /// Size of the uncompressed data in bytes.
  final int uncompressedSize;

  /// Offset of the local file header in the archive.
  final int localHeaderOffset;

  /// Compression method (0 = Store, 8 = Deflate).
  final int compressionMethod;

  /// CRC-32 checksum of the uncompressed data.
  final int crc32;

  ArchiveEntry({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.compressionMethod,
    required this.crc32,
  });

  bool get isDirectory => name.endsWith('/');
  bool get isStored => compressionMethod == 0;
  bool get isDeflated => compressionMethod == 8;

  @override
  String toString() =>
      'ArchiveEntry(name=$name, compressed=$compressedSize, '
      'uncompressed=$uncompressedSize, method=$compressionMethod)';
}
