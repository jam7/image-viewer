import 'dart:typed_data';

import 'archive_entry.dart';

/// Abstract archive reader interface.
/// Implementations parse archive metadata and extract individual entries
/// using range reads, without downloading the entire archive.
abstract class ArchiveReader {
  /// List all entries (files) in the archive.
  /// Reads only the archive's directory structure, not file contents.
  Future<List<ArchiveEntry>> listEntries();

  /// Read and decompress a single entry.
  Future<Uint8List> readEntry(ArchiveEntry entry);
}
