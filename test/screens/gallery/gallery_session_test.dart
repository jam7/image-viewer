import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/widgets/thumbnail_result.dart';

/// Tests the GallerySession paging + thumbnail-feed logic (ADR 007) without UI.
void main() {
  late Directory tempDir;
  late CacheManager cache;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('gallery_session_test');
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

  GallerySession session(_FakePagedSource source) => GallerySession(
    sourceUri: Uri.parse('test://x'),
    provider: source,
    cacheManager: cache,
  );

  test('finite source: one page, hasMore becomes false', () async {
    final t = session(_FakePagedSource([
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
    final t = session(_FakePagedSource([
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
    final t = GallerySession(
      sourceUri: Uri.parse('fav://'),
      provider: source,
      cacheManager: cache,
      seedItems: [img('a'), img('b')],
    );

    final added = await t.loadNextPage();

    expect(added.map((i) => i.id), ['a', 'b']);
    expect(t.loaded.map((i) => i.id), ['a', 'b']);
    expect(t.hasMore, isFalse);
    expect(source.loadPageCalls, 0);
  });

  // The thumbnail machinery that used to be tested here — the loader's batch
  // watermark, its ledger of dispatched items, and the drop-everything /
  // read-it-all-back pair around leaving a view — no longer exists (ADR 011).
  // What replaced it is tested where it now lives: the scheduler's own tests
  // for ordering and fetching, thumbnail_pool_test for what is kept, and
  // thumbnail_supply_test for what a reader is promised.

  test('reloading asks again for what failed, here and nowhere else',
      () async {
    // A tile showing an icon is the main reason anyone reloads, and a settled
    // failure would otherwise last until the app restarts (ADR 011).
    final t = session(_FakePagedSource([
      [img('a'), img('b')],
    ]));
    await t.loadNextPage();
    cache.thumbnails.put('a', ThumbnailFailed(ThumbnailFailReason.notSupported));
    cache.thumbnails.put('b', ThumbnailData(Uint8List.fromList([1])));
    // Another place's failure, in the same app-wide pool.
    cache.thumbnails.put('elsewhere', ThumbnailFailed(ThumbnailFailReason.timeout));

    t.forgetFailedThumbnails();

    expect(cache.thumbnails.get('a'), isNull, reason: 'asked again');
    expect(cache.thumbnails.get('b'), isA<ThumbnailData>(), reason: 'kept');
    expect(cache.thumbnails.get('elsewhere'), isNotNull,
        reason: 'not what was reloaded');
  });

  /// What is on screen belongs to the place, not to the widget drawing it:
  /// the viewer walks the same list looking for neighbours (ADR 010).
  group('visibleItems', () {
    ImageSource work(String id, int pages) => ImageSource(
          id: id,
          name: id,
          uri: id,
          type: ImageSourceType.pixiv,
          metadata: {'pageCount': pages},
        );

    Future<GallerySession> pixivPage(List<ImageSource> items) async {
      final t = GallerySession(
        sourceUri: pixivGalleryUri('/top'),
        provider: _FakePagedSource([items]),
        cacheManager: cache,
      );
      await t.loadNextPage();
      return t;
    }

    test('unfiltered, it is the loaded list itself', () async {
      final t = await pixivPage([work('a', 1), work('b', 3)]);
      expect(t.visibleItems, same(t.loaded));
    });

    test('"N+" keeps the works with N pages and more', () async {
      final t = await pixivPage([work('a', 1), work('b', 3), work('c', 5)]);

      t.minPageCount = 3;

      expect(t.visibleItems.map((i) => i.id), ['b', 'c']);
      expect(t.loaded.length, 3); // narrowed, not thrown away
    });

    test('and widening again brings them back', () async {
      final t = await pixivPage([work('a', 1), work('b', 3)]);
      t.minPageCount = 3;
      expect(t.visibleItems.length, 1);

      t.minPageCount = 0;

      expect(t.visibleItems.length, 2);
    });

    test('a page that arrives while narrowed is filtered too', () async {
      // The list is held between builds rather than rebuilt, so the moment it
      // stops being true has to be the moment it is dropped.
      final source = _FakePagedSource([
        [work('a', 1), work('b', 3)],
        [work('c', 1), work('d', 5)],
      ]);
      final t = GallerySession(
        sourceUri: pixivGalleryUri('/top'),
        provider: source,
        cacheManager: cache,
      );
      await t.loadNextPage();
      t.minPageCount = 3;
      expect(t.visibleItems.map((i) => i.id), ['b']);

      await t.loadNextPage();

      expect(t.visibleItems.map((i) => i.id), ['b', 'd']);
    });
  });

  /// A place opened by typing its address, or restored from disk, arrives with
  /// no name — nobody was there to supply one. The contents carry it.
  group('learning a title from the first page', () {
    ImageSource work(String id, {String? author}) => ImageSource(
          id: id,
          name: id,
          uri: id,
          type: ImageSourceType.pixiv,
          metadata: {'author': ?author},
        );

    GallerySession authorPage(_FakePagedSource source, {String title = ''}) =>
        GallerySession(
          sourceUri: pixivGalleryUri('/user/1700000000000'),
          provider: source,
          cacheManager: cache,
          title: title,
        );

    test('the author page takes its name out of its own works', () async {
      final t = authorPage(_FakePagedSource([
        [work('a', author: 'テスト作者')],
      ]));
      expect(t.title, isEmpty); // the URI answers for now: 1700000000000 の作品

      await t.loadNextPage();

      expect(t.title, 'テスト作者 の作品');
    });

    test('a name given up front is not overwritten by the fetch', () async {
      // Following a link from the viewer already knows the author. Keeping it
      // is what stops the header showing a number and then changing.
      final t = authorPage(
        _FakePagedSource([
          [work('a', author: 'テスト作者')]
        ]),
        title: 'テスト作者 の作品',
      );

      await t.loadNextPage();

      expect(t.title, 'テスト作者 の作品');
    });

    test('items that say nothing leave the place unnamed', () async {
      final t = authorPage(_FakePagedSource([
        [work('a')],
      ]));

      await t.loadNextPage();

      expect(t.title, isEmpty);
    });

    test('the tab hears about it, since the header watches the tab', () async {
      final tab = GalleryTab(authorPage(_FakePagedSource([
        [work('a', author: 'テスト作者')],
      ])));
      final before = tab.revision.value;

      await tab.current.loadNextPage();

      expect(tab.revision.value, greaterThan(before));
    });
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
