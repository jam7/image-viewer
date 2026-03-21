import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../archive_entry.dart';
import '../archive_reader_base.dart';
import '../range_reader.dart';

final _log = Logger('ZipReader');

/// ZIP archive reader using range reads.
///
/// Reads the End of Central Directory (EOCD) and Central Directory
/// to build a file list, then extracts individual entries via range
/// reads without downloading the entire archive.
class ZipReader implements ArchiveReader {
  final RangeReader readRange;
  final int fileSize;

  List<ArchiveEntry>? _entries;

  ZipReader({required this.readRange, required this.fileSize});

  @override
  Future<List<ArchiveEntry>> listEntries() async {
    if (_entries != null) return _entries!;
    _entries = await _parseDirectory();
    return _entries!;
  }

  @override
  Future<Uint8List> readEntry(ArchiveEntry entry) async {
    // Read local file header to determine actual data offset.
    // Local header: 30 bytes fixed + variable file name + extra field.
    final localHeader = await readRange(entry.localHeaderOffset, 30);
    _validateLocalHeader(localHeader);

    final fileNameLen = _readUint16(localHeader, 26);
    final extraFieldLen = _readUint16(localHeader, 28);
    final dataOffset = entry.localHeaderOffset + 30 + fileNameLen + extraFieldLen;

    _log.info('readEntry: ${entry.name} offset=$dataOffset '
        'compressed=${entry.compressedSize} method=${entry.compressionMethod}');

    final compressedData = await readRange(dataOffset, entry.compressedSize);

    if (entry.isStored) {
      return compressedData;
    } else if (entry.isDeflated) {
      return _inflate(compressedData, entry.uncompressedSize);
    } else {
      throw UnsupportedError(
          'Unsupported compression method: ${entry.compressionMethod}');
    }
  }

  // --- EOCD and Central Directory parsing ---

  Future<List<ArchiveEntry>> _parseDirectory() async {
    // EOCD is at the end of the file. Minimum 22 bytes, max 22 + 65535
    // (if there's a ZIP comment). Read last 65KB to be safe.
    final eocdSearchSize = fileSize < 65558 ? fileSize : 65558;
    final tailOffset = fileSize - eocdSearchSize;
    final tail = await readRange(tailOffset, eocdSearchSize);

    _log.info('Searching for EOCD in last $eocdSearchSize bytes');

    // Find EOCD signature (0x06054b50) scanning backwards
    int eocdPos = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 && tail[i + 1] == 0x4b &&
          tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
        eocdPos = i;
        break;
      }
    }
    if (eocdPos < 0) {
      throw FormatException('ZIP EOCD signature not found');
    }

    final cdEntryCount = _readUint16(tail, eocdPos + 10);
    final cdSize = _readUint32(tail, eocdPos + 12);
    final cdOffset = _readUint32(tail, eocdPos + 16);

    _log.info('EOCD found: $cdEntryCount entries, '
        'CD offset=$cdOffset, CD size=$cdSize');

    // Read the Central Directory
    final cd = await readRange(cdOffset, cdSize);

    final entries = <ArchiveEntry>[];
    var pos = 0;
    for (var i = 0; i < cdEntryCount; i++) {
      if (pos + 46 > cd.length) {
        _log.warning('Central Directory truncated at entry $i');
        break;
      }

      // Validate Central Directory file header signature (0x02014b50)
      if (cd[pos] != 0x50 || cd[pos + 1] != 0x4b ||
          cd[pos + 2] != 0x01 || cd[pos + 3] != 0x02) {
        throw FormatException('Invalid Central Directory entry signature at offset $pos');
      }

      final compressionMethod = _readUint16(cd, pos + 10);
      final crc32 = _readUint32(cd, pos + 16);
      final compressedSize = _readUint32(cd, pos + 20);
      final uncompressedSize = _readUint32(cd, pos + 24);
      final fileNameLen = _readUint16(cd, pos + 28);
      final extraLen = _readUint16(cd, pos + 30);
      final commentLen = _readUint16(cd, pos + 32);
      final localHeaderOffset = _readUint32(cd, pos + 42);

      final nameBytes = cd.sublist(pos + 46, pos + 46 + fileNameLen);
      final name = String.fromCharCodes(nameBytes);

      entries.add(ArchiveEntry(
        name: name,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
        compressionMethod: compressionMethod,
        crc32: crc32,
      ));

      pos += 46 + fileNameLen + extraLen + commentLen;
    }

    _log.info('Parsed $cdEntryCount entries from Central Directory');
    return entries;
  }

  void _validateLocalHeader(Uint8List header) {
    if (header.length < 30 ||
        header[0] != 0x50 || header[1] != 0x4b ||
        header[2] != 0x03 || header[3] != 0x04) {
      throw FormatException('Invalid local file header signature');
    }
  }

  Uint8List _inflate(Uint8List compressed, int uncompressedSize) {
    // Raw deflate (no zlib/gzip header)
    final inflated = ZLibCodec(raw: true).decode(compressed);
    return Uint8List.fromList(inflated);
  }

  // --- Little-endian readers ---

  static int _readUint16(Uint8List data, int offset) =>
      data[offset] | (data[offset + 1] << 8);

  static int _readUint32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}
