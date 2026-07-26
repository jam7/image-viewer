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

  GallerySession session(_FakePagedSource source,
      {bool Function(ImageSource)? filter, void Function()? onChanged}) {
    return GallerySession(
      sourceUri: Uri.parse('test://x'),
      provider: source,
      cacheManager: cache,
      thumbnailFilter: filter,
    )..onChanged = onChanged;
  }

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

  test('thumbnailFilter excludes directories from the loader', () async {
    final source = _FakePagedSource([
      [img('dir', dir: true), img('a'), img('b')],
    ]);
    final t = session(source, filter: (i) => i.metadata?['isDirectory'] != true);

    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();

    // dir is shown in loaded but not fetched as a thumbnail.
    expect(t.loaded.length, 3);
    expect(source.thumbnailIds, ['a', 'b']);
  });

  test('needsBatchFor: true past the dispatched range, false for directories',
      () async {
    // batchSize is galleryCrossAxisCount * 6 = 30, so page 1 fills one batch
    // exactly and page 2 lands beyond it.
    final page1 = [
      img('dir', dir: true),
      for (var i = 0; i < 30; i++) img('p1-$i'),
    ];
    final t = session(
      _FakePagedSource([page1, [img('p2-0')]]),
      filter: (i) => i.metadata?['isDirectory'] != true,
    );

    await t.loadNextPage();
    await t.loadNextPage();
    await t.thumbnails.loadNextBatch(); // dispatches the first 30

    expect(t.needsBatchFor(page1[1]), isFalse); // inside the dispatched range
    expect(t.needsBatchFor(img('p2-0')), isTrue); // beyond it
    expect(t.needsBatchFor(page1[0]), isFalse); // directory: never batched
  });

  test('loader results are stored on the session and reported once each',
      () async {
    var changes = 0;
    final t = session(
      _FakePagedSource([
        [img('a'), img('b')],
      ]),
      onChanged: () => changes++,
    );

    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();

    expect(t.thumbnailFor('a'), isA<ThumbnailData>());
    expect(t.thumbnailFor('b'), isA<ThumbnailData>());
    expect(t.thumbnailFor('missing'), isNull);
    expect(t.hasThumbnailResults, isTrue);
    expect(changes, 2);
  });

  test('detach clears the results but keeps the item list', () async {
    var changes = 0;
    final t = session(
      _FakePagedSource([
        [img('a')],
      ]),
      onChanged: () => changes++,
    );
    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();
    changes = 0;

    t.detach();

    expect(t.hasThumbnailResults, isFalse);
    expect(t.thumbnailFor('a'), isNull);
    expect(t.loaded.map((i) => i.id), ['a']); // items survive the detach
    // No repaint request: this runs from deactivate, i.e. during a build.
    expect(changes, 0);
  });

  test('a failure survives detach, since nothing could restore it', () async {
    // A PDF with no cached bytes cannot have a thumbnail made for it, and that
    // answer is not in the cache to be read back.
    final source = _FakePagedSource([
      [img('ok'), img('nope')],
    ], unsupported: {'nope'});
    final t = session(source);
    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();
    expect(t.thumbnailFor('nope'), isA<ThumbnailFailed>());

    t.detach();

    expect(t.thumbnailFor('ok'), isNull); // decoded image dropped
    expect(t.thumbnailFor('nope'), isA<ThumbnailFailed>()); // answer kept

    await t.attach();

    // Still answered, and not fetched again just to fail the same way.
    expect(t.thumbnailFor('nope'), isA<ThumbnailFailed>());
    expect(source.thumbnailIds.where((id) => id == 'nope').length, 1);
  });

  test('attach refetches what the cache no longer has', () async {
    // Clearing the cache while a tab is in the background: detach dropped the
    // decoded images, and attach finds nothing to read back. The loader counts
    // these as answered, so without a retry the whole tab stays spinners for as
    // long as it lives -- only a newly opened tab shows anything.
    final source = _FakePagedSource([
      [img('a'), img('b')],
    ]);
    final t = session(source);
    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();
    expect(source.thumbnailIds, ['a', 'b']);

    t.detach();
    await cache.clearL2();
    await t.attach();

    expect(source.thumbnailIds, ['a', 'b', 'a', 'b']);
    expect(t.thumbnailFor('a'), isA<ThumbnailData>());
    expect(t.thumbnailFor('b'), isA<ThumbnailData>());
  });

  test('attach restores thumbnails from the cache without refetching',
      () async {
    final source = _FakePagedSource([
      [img('a'), img('b')],
    ]);
    final t = session(source);
    await t.loadNextPage();
    await t.thumbnails.loadNextBatch(); // populates thumb: in the cache
    expect(source.thumbnailIds, ['a', 'b']);

    t.detach();
    await t.attach();

    expect(t.thumbnailFor('a'), isA<ThumbnailData>());
    expect(t.thumbnailFor('b'), isA<ThumbnailData>());
    expect(source.thumbnailIds, ['a', 'b']); // came from the cache, not the source
  });

  test('attach ignores the full: entry, only thumb:', () async {
    final source = _FakePagedSource([
      [img('a')],
    ]);
    final t = session(source);
    await t.loadNextPage();
    // Only a full-size entry exists — the thumbnail fetch never succeeded.
    await cache.l2.put('full:a', Uint8List.fromList(const [1, 2, 3]));

    await t.attach();

    // Showing the full-size decode behind a grid tile is what the thumb:-only
    // rule exists to prevent.
    expect(t.thumbnailFor('a'), isNull);
  });

  test('detaching again mid-attach stops the reload', () async {
    final source = _FakePagedSource([
      [img('a'), img('b')],
    ]);
    final t = session(source);
    await t.loadNextPage();
    await t.thumbnails.loadNextBatch();

    t.detach();
    final reload = t.attach();
    t.detach(); // e.g. the view went away again straight after coming back
    await reload;

    expect(t.hasThumbnailResults, isFalse);
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

  /// Ids that cannot have a thumbnail made (an uncached PDF, a ZIP of nothing).
  final Set<String> unsupported;
  int loadPageCalls = 0;

  _FakePagedSource(this.pages, {this.unsupported = const {}})
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
    if (unsupported.contains(source.id)) {
      throw ThumbnailNotSupportedException(source.id);
    }
    return Uint8List.fromList(const [1]);
  }
}
