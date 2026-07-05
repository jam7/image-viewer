import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/thumbnail/thumbnail_loader.dart';

/// Tests the GalleryTab paging + thumbnail-feed logic (ADR 007) without UI.
void main() {
  late Directory tempDir;
  late CacheManager cache;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('gallery_tab_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 200), l2: l2, l3: l3);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ImageSource img(String id, {bool dir = false}) => ImageSource(
        id: id,
        name: id,
        uri: id,
        type: ImageSourceType.smb,
        metadata: {'isDirectory': dir},
      );

  GalleryTab tab(_FakePagedSource source,
      {bool Function(ImageSource)? filter}) {
    final loader = ThumbnailLoader(
      source: source,
      cacheManager: cache,
      batchSize: 30,
      parallelCount: 5,
      onResult: (_, _) {},
    );
    return GalleryTab(
      sourceUri: Uri.parse('test://x'),
      provider: source,
      thumbnails: loader,
      thumbnailFilter: filter,
    );
  }

  test('finite source: one page, hasMore becomes false', () async {
    final t = tab(_FakePagedSource([
      [img('a'), img('b')],
    ]));
    expect(t.hasMore, isTrue); // nothing loaded yet

    final added = await t.loadNextPage();

    expect(added.map((i) => i.id), ['a', 'b']);
    expect(t.loaded.map((i) => i.id), ['a', 'b']);
    expect(t.hasMore, isFalse);
    // Exhausted: further calls are no-ops.
    expect(await t.loadNextPage(), isEmpty);
  });

  test('paged source: appends pages and tracks cursor', () async {
    final t = tab(_FakePagedSource([
      [img('a'), img('b')],
      [img('c'), img('d')],
    ]));

    await t.loadNextPage();
    expect(t.hasMore, isTrue); // cursor points to page 2
    await t.loadNextPage();

    expect(t.loaded.map((i) => i.id), ['a', 'b', 'c', 'd']);
    expect(t.hasMore, isFalse);
  });

  test('seedItems: finite list served as one page, no provider call', () async {
    final source = _FakePagedSource(const []); // provider.loadPage must not be called
    final loader = ThumbnailLoader(
      source: source,
      cacheManager: cache,
      batchSize: 30,
      parallelCount: 5,
      onResult: (_, _) {},
    );
    final t = GalleryTab(
      sourceUri: Uri.parse('fav://'),
      provider: source,
      thumbnails: loader,
      seedItems: [img('a'), img('b')],
    );

    final added = await t.loadNextPage();

    expect(added.map((i) => i.id), ['a', 'b']);
    expect(t.loaded.map((i) => i.id), ['a', 'b']);
    expect(t.hasMore, isFalse);
    expect(source.loadPageCalls, 0);
  });

  test('thumbnailFilter excludes directories from the loader', () async {
    final source = _FakePagedSource([
      [img('dir', dir: true), img('a'), img('b')],
    ]);
    final t = tab(source, filter: (i) => i.metadata?['isDirectory'] != true);

    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();

    // dir is shown in loaded but not fetched as a thumbnail.
    expect(t.loaded.length, 3);
    expect(source.thumbnailIds, ['a', 'b']);
  });
}

/// Fake source: serves canned pages via loadPage, records thumbnail fetches.
class _FakePagedSource extends SmbSource {
  final List<List<ImageSource>> pages;
  final List<String> thumbnailIds = [];
  int loadPageCalls = 0;

  _FakePagedSource(this.pages)
      : super(
          config: const ServerConfig(
            id: 't',
            name: 't',
            type: ImageSourceType.smb,
            host: 'localhost',
          ),
          password: '',
        );

  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async {
    loadPageCalls++;
    final index = (cursor as int?) ?? 0;
    return PageResult(
      items: pages[index],
      nextCursor: index + 1 < pages.length ? index + 1 : null,
    );
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    thumbnailIds.add(source.id);
    return Uint8List.fromList(const [1]);
  }
}
