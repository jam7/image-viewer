import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive_reader/archive_reader.dart';
import 'package:test/test.dart';

/// Create a test ZIP in memory with known contents.
Uint8List _createTestZip({bool useDeflate = false}) {
  final archive = Archive();

  archive.addFile(ArchiveFile.bytes(
    'images/03.jpg',
    Uint8List.fromList(List.generate(100, (i) => i % 256)),
  ));
  archive.addFile(ArchiveFile.bytes(
    'images/01.jpg',
    Uint8List.fromList(List.generate(200, (i) => (i * 7) % 256)),
  ));
  archive.addFile(ArchiveFile.bytes(
    'images/02.jpg',
    Uint8List.fromList(List.generate(150, (i) => (i * 3) % 256)),
  ));
  archive.addFile(ArchiveFile.bytes(
    'readme.txt',
    Uint8List.fromList('Hello, world!'.codeUnits),
  ));

  final encoder = ZipEncoder();
  if (!useDeflate) {
    return Uint8List.fromList(encoder.encode(archive, level: DeflateLevel.none));
  }
  return Uint8List.fromList(encoder.encode(archive));
}

RangeReader _memoryRangeReader(Uint8List data) {
  return (int offset, int length) async {
    final end = offset + length > data.length ? data.length : offset + length;
    return Uint8List.sublistView(data, offset, end);
  };
}

void main() {
  group('ZipReader (Store)', () {
    late Uint8List zipData;
    late ZipReader reader;

    setUp(() {
      zipData = _createTestZip(useDeflate: false);
      reader = ZipReader(
        readRange: _memoryRangeReader(zipData),
        fileSize: zipData.length,
      );
    });

    test('listEntries returns all files', () async {
      final entries = await reader.listEntries();
      expect(entries.length, 4);
      expect(entries.map((e) => e.name).toList(),
          containsAll(['images/01.jpg', 'images/02.jpg', 'images/03.jpg', 'readme.txt']));
    });

    test('readEntry returns correct data for stored files', () async {
      final entries = await reader.listEntries();
      final entry01 = entries.firstWhere((e) => e.name == 'images/01.jpg');
      final data = await reader.readEntry(entry01);
      expect(data.length, 200);
      expect(data[0], 0);
      expect(data[1], 7 % 256);
    });

    test('entries have correct sizes', () async {
      final entries = await reader.listEntries();
      final entry03 = entries.firstWhere((e) => e.name == 'images/03.jpg');
      expect(entry03.uncompressedSize, 100);
      // Note: archive package may use Deflate even with DeflateLevel.none,
      // so we only check that readEntry returns correct data regardless.
    });
  });

  group('ZipReader (Deflate)', () {
    late Uint8List zipData;
    late ZipReader reader;

    setUp(() {
      zipData = _createTestZip(useDeflate: true);
      reader = ZipReader(
        readRange: _memoryRangeReader(zipData),
        fileSize: zipData.length,
      );
    });

    test('listEntries returns all files', () async {
      final entries = await reader.listEntries();
      expect(entries.length, 4);
    });

    test('readEntry inflates deflated data correctly', () async {
      final entries = await reader.listEntries();
      final entry01 = entries.firstWhere((e) => e.name == 'images/01.jpg');
      final data = await reader.readEntry(entry01);
      expect(data.length, 200);
      expect(data[0], 0);
      expect(data[1], 7 % 256);
    });

    test('readEntry for text file', () async {
      final entries = await reader.listEntries();
      final readme = entries.firstWhere((e) => e.name == 'readme.txt');
      final data = await reader.readEntry(readme);
      expect(String.fromCharCodes(data), 'Hello, world!');
    });
  });

  test('listEntries is cached', () async {
    final zipData = _createTestZip();
    var callCount = 0;
    final reader = ZipReader(
      readRange: (offset, length) async {
        callCount++;
        final end = offset + length > zipData.length ? zipData.length : offset + length;
        return Uint8List.sublistView(zipData, offset, end);
      },
      fileSize: zipData.length,
    );

    await reader.listEntries();
    final firstCallCount = callCount;
    await reader.listEntries();
    expect(callCount, firstCallCount, reason: 'Second call should use cache');
  });

  test('concurrent listEntries calls share one parse', () async {
    final zipData = _createTestZip();
    var callCount = 0;
    final reader = ZipReader(
      readRange: (offset, length) async {
        callCount++;
        final end = offset + length > zipData.length ? zipData.length : offset + length;
        return Uint8List.sublistView(zipData, offset, end);
      },
      fileSize: zipData.length,
    );

    // Fire two concurrent calls
    final results = await Future.wait([
      reader.listEntries(),
      reader.listEntries(),
    ]);
    expect(results[0], same(results[1]), reason: 'Should return same list');
  });

  test('readEntry verifies CRC-32 (no exception on valid data)', () async {
    final zipData = _createTestZip();
    final reader = ZipReader(
      readRange: _memoryRangeReader(zipData),
      fileSize: zipData.length,
    );
    final entries = await reader.listEntries();
    // Should not throw — CRC matches
    for (final entry in entries) {
      await reader.readEntry(entry);
    }
  });
}
