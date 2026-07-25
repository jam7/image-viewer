import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/thumbnail/thumbnail_loader.dart';
import 'package:image_viewer/widgets/thumbnail_result.dart';

/// Unit tests for the generic (source-agnostic) contract of ThumbnailLoader:
/// cache hit/miss, fetch → cache → emit, exception → typed failure, parallel
/// batch, and cancel delegating to the source. These pin the behavior the
/// Step 2 generalization (ADR 006) must preserve.
///
/// The video-capture path (proxy + media_kit) is intentionally NOT covered
/// here — it needs a real device and is verified there.
void main() {
  late Directory tempDir;
  late CacheManager cache;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('thumb_loader_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 200), l2: l2, l3: l3);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ImageSource img(String id) => ImageSource(
        id: id,
        name: '$id.jpg',
        uri: 'smb://server/share/$id.jpg',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
        metadata: const {},
      );

  ThumbnailLoader loader(
    _FakeSource source,
    void Function(String id, ThumbnailResult result) onResult,
  ) =>
      ThumbnailLoader(
        source: source,
        cacheManager: cache,
        batchSize: 30,
        parallelCount: 5,
        onResult: onResult,
      );

  test('cache hit emits the cached bytes without fetching', () async {
    cache.l1.put('thumb:a', Uint8List.fromList([1, 2, 3]));
    final source = _FakeSource(onFetch: (_) async => Uint8List.fromList([9]));
    final results = <String, ThumbnailResult>{};
    final l = loader(source, (id, r) => results[id] = r)..setItems([img('a')]);

    await l.loadNextBatch();

    expect(source.fetchCount, 0);
    final r = results['a'];
    expect(r, isA<ThumbnailData>());
    expect((r as ThumbnailData).data, [1, 2, 3]);
  });

  test('cache miss fetches, caches to L1+L2, and emits', () async {
    final source =
        _FakeSource(onFetch: (_) async => Uint8List.fromList([4, 5, 6]));
    final results = <String, ThumbnailResult>{};
    final l = loader(source, (id, r) => results[id] = r)..setItems([img('a')]);

    await l.loadNextBatch();

    expect(source.fetchCount, 1);
    expect((results['a'] as ThumbnailData).data, [4, 5, 6]);
    // Cached for next time.
    expect(cache.l1.get('thumb:a'), [4, 5, 6]);
    expect((await cache.get('thumb:a'))?.data, [4, 5, 6]);
  });

  test('ThumbnailNotSupportedException maps to notSupported', () async {
    final source = _FakeSource(
        onFetch: (_) async => throw ThumbnailNotSupportedException('x'));
    final results = <String, ThumbnailResult>{};
    final l = loader(source, (id, r) => results[id] = r)..setItems([img('a')]);

    await l.loadNextBatch();

    expect(results['a'], isA<ThumbnailFailed>());
    expect((results['a'] as ThumbnailFailed).reason,
        ThumbnailFailReason.notSupported);
  });

  test('other errors map to timeout', () async {
    final source = _FakeSource(onFetch: (_) async => throw Exception('boom'));
    final results = <String, ThumbnailResult>{};
    final l = loader(source, (id, r) => results[id] = r)..setItems([img('a')]);

    await l.loadNextBatch();

    expect((results['a'] as ThumbnailFailed).reason,
        ThumbnailFailReason.timeout);
  });

  test('a batch emits a result for every item', () async {
    final source =
        _FakeSource(onFetch: (s) async => Uint8List.fromList([s.id.length]));
    final results = <String, ThumbnailResult>{};
    final items = [for (var i = 0; i < 12; i++) img('item$i')];
    final l = loader(source, (id, r) => results[id] = r)..setItems(items);

    await l.loadNextBatch();

    expect(results.length, 12);
    expect(results.values.every((r) => r is ThumbnailData), isTrue);
  });

  test('addItems appends without reloading already-loaded items', () async {
    final source =
        _FakeSource(onFetch: (s) async => Uint8List.fromList([s.id.length]));
    final results = <String, ThumbnailResult>{};
    final l = loader(source, (id, r) => results[id] = r)
      ..setItems([img('a'), img('b')]);

    await l.loadNextBatch();
    expect(source.fetchCount, 2);

    l.addItems([img('c'), img('d')]);
    expect(l.itemCount, 4);

    await l.loadNextBatch();
    // Only c and d fetched; a and b kept their results.
    expect(source.fetchCount, 4);
    expect(results.keys.toSet(), {'a', 'b', 'c', 'd'});
  });

  test('retryUnsupported re-fetches the items it selects', () async {
    var supported = false;
    final source = _FakeSource(onFetch: (_) async {
      if (!supported) throw ThumbnailNotSupportedException('x');
      return Uint8List.fromList([7]);
    });
    final results = <String, ThumbnailResult>{};
    // retryUnsupported does not await the reload, so wait on the result itself
    // rather than on a fixed number of event-loop turns.
    final retried = Completer<void>();
    final l = loader(source, (id, r) {
      results[id] = r;
      if (id == 'a' && r is ThumbnailData && !retried.isCompleted) {
        retried.complete();
      }
    })..setItems([img('a'), img('b')]);

    await l.loadNextBatch();
    expect(source.fetchCount, 2);
    expect((results['a'] as ThumbnailFailed).reason,
        ThumbnailFailReason.notSupported);

    // Standing in for the viewer having cached the data meanwhile.
    supported = true;
    l.retryUnsupported((id) => id == 'a');
    await retried.future.timeout(const Duration(seconds: 5));

    expect(source.fetchCount, 3); // only 'a' refetched
    expect(results['a'], isA<ThumbnailData>());
    expect(results['b'], isA<ThumbnailFailed>()); // untouched by the retry
  });

  test('cancel delegates to source.cancelThumbnailWork', () async {
    final source =
        _FakeSource(onFetch: (_) async => Uint8List.fromList([1]));
    final l = loader(source, (_, _) {});

    l.cancel();

    expect(source.cancelCount, 1);
  });
}

/// Fake source exercising ThumbnailLoader's generic path. Overrides only
/// fetchThumbnail and cancelThumbnailWork; the SMB machinery is never touched.
class _FakeSource extends SmbSource {
  final Future<Uint8List> Function(ImageSource source) onFetch;
  int fetchCount = 0;
  int cancelCount = 0;

  _FakeSource({required this.onFetch})
      : super(
          config: const ServerConfig(
            id: 'test',
            name: 'test',
            type: ImageSourceType.smb,
            host: 'localhost',
          ),
          password: '',
        );

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) {
    fetchCount++;
    return onFetch(source);
  }

  @override
  void cancelThumbnailWork() => cancelCount++;
}
