import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';

/// Characterization tests: pin down DiskCache's current behavior before
/// refactoring (get/getFilePath dedup). They describe what the code does
/// today, not necessarily what it should do.
void main() {
  late Directory tempDir;
  late DiskCache cache;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('disk_cache_test');
    cache = DiskCache(maxSizeBytes: 1000);
    await cache.init(baseDir: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Uint8List bytes(int n, [int fill = 7]) =>
      Uint8List.fromList(List.filled(n, fill));

  test('uninitialized cache answers null without touching the disk', () async {
    final fresh = DiskCache();
    expect(await fresh.get('k'), isNull);
    expect(fresh.getFilePath('k'), isNull);
  });

  test('put/get roundtrip; getFilePath points at the backing file', () async {
    await cache.put('a', bytes(10, 1));
    expect(await cache.get('a'), bytes(10, 1));

    final path = cache.getFilePath('a');
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), bytes(10, 1));

    expect(await cache.get('missing'), isNull);
    expect(cache.getFilePath('missing'), isNull);
  });

  test('put on an existing key replaces it with exact size accounting',
      () async {
    await cache.put('a', bytes(100));
    await cache.put('a', bytes(50, 2));

    final stats = await cache.getStats();
    expect(stats.itemCount, 1);
    expect(stats.totalSizeBytes, 50);
    expect(await cache.get('a'), bytes(50, 2));
  });

  test('get self-heals when the backing file vanished', () async {
    await cache.put('a', bytes(40));
    File(cache.getFilePath('a')!).deleteSync();

    expect(await cache.get('a'), isNull);
    final stats = await cache.getStats();
    expect(stats.itemCount, 0);
    expect(stats.totalSizeBytes, 0);
  });

  test('getFilePath self-heals when the backing file vanished', () async {
    await cache.put('a', bytes(40));
    File(cache.getFilePath('a')!).deleteSync();

    expect(cache.getFilePath('a'), isNull);
    final stats = await cache.getStats();
    expect(stats.itemCount, 0);
    expect(stats.totalSizeBytes, 0);
  });

  test('eviction removes the least-recently-accessed entry', () async {
    // maxSizeBytes=1000: three 400-byte entries cannot coexist.
    await cache.put('a', bytes(400));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await cache.put('b', bytes(400));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await cache.get('a'); // Refresh a: b becomes the oldest.
    await Future<void>.delayed(const Duration(milliseconds: 5));

    await cache.put('c', bytes(400));

    expect(await cache.get('b'), isNull, reason: 'oldest entry is evicted');
    expect(await cache.get('a'), isNotNull);
    expect(await cache.get('c'), isNotNull);
    expect((await cache.getStats()).totalSizeBytes, 800);
  });

  test('delete removes the entry and its file', () async {
    await cache.put('a', bytes(10));
    final path = cache.getFilePath('a')!;

    cache.delete('a');

    expect(await cache.get('a'), isNull);
    expect(File(path).existsSync(), isFalse);
    expect((await cache.getStats()).totalSizeBytes, 0);
  });

  test('metadata persists across instances once the flush threshold is hit',
      () async {
    // _scheduleFlush writes metadata every 5 ops; 5 puts cross it.
    for (var i = 0; i < 5; i++) {
      await cache.put('k$i', bytes(10, i));
    }
    // The flush is fire-and-forget; give it a moment to land.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final reopened = DiskCache(maxSizeBytes: 1000);
    await reopened.init(baseDir: tempDir);

    expect((await reopened.getStats()).itemCount, 5);
    expect(await reopened.get('k3'), bytes(10, 3));
  });

  test('clear removes all entries and files', () async {
    await cache.put('a', bytes(10));
    await cache.put('b', bytes(10));

    await cache.clear();

    expect(await cache.get('a'), isNull);
    final stats = await cache.getStats();
    expect(stats.itemCount, 0);
    expect(stats.totalSizeBytes, 0);
  });
}
