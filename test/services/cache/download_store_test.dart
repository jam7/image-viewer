import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/services/cache/download_store.dart';

/// Characterization tests: pin down DownloadStore's current behavior
/// before refactoring. They describe what the code does today.
void main() {
  late Directory tempDir;
  late DownloadStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('download_store_test');
    store = DownloadStore();
    await store.init(baseDir: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Uint8List bytes(int n, [int fill = 7]) =>
      Uint8List.fromList(List.filled(n, fill));

  test('put marks the key downloaded and get returns the data', () async {
    expect(store.isDownloaded('a'), isFalse);

    await store.put('a', bytes(10, 1), {'name': 'a.jpg'});

    expect(store.isDownloaded('a'), isTrue);
    expect(await store.get('a'), bytes(10, 1));
    expect(File(store.getFilePath('a')!).readAsBytesSync(), bytes(10, 1));
  });

  test('remove deletes the entry and its file', () async {
    await store.put('a', bytes(10), null);
    final path = store.getFilePath('a')!;

    await store.remove('a');

    expect(store.isDownloaded('a'), isFalse);
    expect(await store.get('a'), isNull);
    expect(File(path).existsSync(), isFalse);
  });

  test('toggle stores when absent (true) and removes when present (false)',
      () async {
    expect(await store.toggle('a', bytes(10), null), isTrue);
    expect(store.isDownloaded('a'), isTrue);

    expect(await store.toggle('a', null, null), isFalse);
    expect(store.isDownloaded('a'), isFalse);
  });

  test('toggle without data on an absent key stores nothing', () async {
    expect(await store.toggle('a', null, null), isFalse);
    expect(store.isDownloaded('a'), isFalse);
  });

  test('putFromStream stores all chunks and reports progress', () async {
    final progress = <int>[];
    final ok = await store.putFromStream(
      'a',
      Stream.fromIterable([bytes(10, 1), bytes(10, 2)]),
      null,
      onProgress: (received, total) => progress.add(received),
      total: 20,
    );

    expect(ok, isTrue);
    expect(progress, [10, 20]);
    final data = await store.get('a');
    expect(data!.length, 20);
    expect(data.sublist(0, 10), bytes(10, 1));
    expect(data.sublist(10), bytes(10, 2));
  });

  test('cancelled putFromStream deletes the partial file', () async {
    final ok = await store.putFromStream(
      'a',
      Stream.fromIterable([bytes(10), bytes(10)]),
      null,
      isCancelled: () => true,
    );

    expect(ok, isFalse);
    expect(store.isDownloaded('a'), isFalse);
    expect(await store.get('a'), isNull);
  });

  test('entries persist across instances (put flushes immediately)', () async {
    await store.put('a', bytes(10, 3), null);

    final reopened = DownloadStore();
    await reopened.init(baseDir: tempDir);

    expect(reopened.isDownloaded('a'), isTrue);
    expect(await reopened.get('a'), bytes(10, 3));
  });

  test('get self-heals a vanished file but (current behavior) keeps the '
      'byte count in stats', () async {
    await store.put('a', bytes(40), null);
    File(store.getFilePath('a')!).deleteSync();

    expect(await store.get('a'), isNull);
    expect(store.isDownloaded('a'), isFalse);
    // Unlike DiskCache, totalSizeBytes is NOT decremented here — pinned as
    // current behavior (see fix-session-20260704-refactor.md).
    expect((await store.getStats()).totalSizeBytes, 40);
  });

  test('clear removes all entries and files', () async {
    await store.put('a', bytes(10), null);
    await store.clear();

    expect(store.isDownloaded('a'), isFalse);
    expect((await store.getStats()).itemCount, 0);
  });
}
