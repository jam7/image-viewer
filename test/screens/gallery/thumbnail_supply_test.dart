import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/smb_gallery_body.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/sources/source_registry.dart';
import 'package:image_viewer/services/video/smb_proxy_server.dart';

/// What the grid promises about thumbnails, written so it outlives the machine
/// that keeps the promise (ADR 011 段階 0).
///
/// The rework replaces how thumbnails are supplied — the batch watermark, the
/// ledger of dispatched items, and the drop-everything-and-reread on leaving a
/// view all go, in favour of tiles asking and a scheduler answering. These
/// tests are therefore written against what a reader can see (a tile shows a
/// picture, an icon, or a spinner) and what the source is asked for, never
/// against the parts being replaced. Each is one of the invariants named in
/// docs/thumbnails/design.md.
void main() {
  late Directory tempDir;
  late CacheManager cacheManager;
  late FavoritesStore favoritesStore;
  late SourceRegistry registry;
  late SmbProxyServer proxyServer;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('thumb_supply_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cacheManager = CacheManager(
      l1: MemoryCache(maxEntries: 200),
      l2: l2,
      l3: l3,
    );
    favoritesStore = FavoritesStore();
    registry = SourceRegistry(smbConfigStore: SmbConfigStore());
    proxyServer = SmbProxyServer();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ImageSource picture(String id) => ImageSource(
    id: id,
    name: '$id.jpg',
    uri: 'smb://server/share/$id.jpg',
    type: ImageSourceType.smb,
    sourceKey: 'smb:test',
    metadata: const {'isDirectory': false},
  );

  ImageSource film(String id) => ImageSource(
    id: id,
    name: '$id.mp4',
    uri: 'smb://server/share/$id.mp4',
    type: ImageSourceType.smb,
    sourceKey: 'smb:test',
    metadata: const {'isDirectory': false, 'isVideo': true},
  );

  /// One tab holding one place, kept across pumps so that leaving the grid and
  /// coming back is the same session — which is what a tab switch does.
  GalleryTab tabFor(SmbSource source) => GalleryTab(
    GallerySession.fromUri(
      smbGalleryUri(source.config.id, '/books'),
      provider: source,
      cacheManager: cacheManager,
      title: 'books',
    ),
  );

  Widget bodyFor(GalleryTab tab) => MaterialApp(
    home: Scaffold(
      body: SmbGalleryBody(
        tab: tab,
        onOpenInNewTab: (_) {},
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        registry: registry,
        proxyServer: proxyServer,
      ),
    ),
  );

  /// A test has no image engine, so bytes that reach a tile cannot be turned
  /// into a picture. That is not what is under test: these ask whether a tile
  /// got its bytes at all, and it says so by being an Image rather than a
  /// spinner, painted or not. Called from inside the test rather than a setUp
  /// because the test framework installs its own handler as the test starts.
  void ignoreUnpaintableThumbnails() {
    final reportToTest = FlutterError.onError!;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('Codec failed')) return;
      reportToTest(details);
    };
  }

  /// Show [widget] and let the work land.
  ///
  /// All of it in real time rather than the widget test's fake clock, because
  /// two things here only happen on the real event loop: storing a thumbnail
  /// writes a file, and painting one decodes it. Under the fake clock the
  /// write never finishes — and the loader waits for it before saying it has
  /// anything, so the grid stays spinners for ever and the test hangs with it.
  Future<void> show(WidgetTester tester, Widget widget) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(widget);
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  final spinners = find.byType(CircularProgressIndicator);
  final pictures = find.byType(Image);

  testWidgets('I1: what is on screen ends up as a picture, not a spinner', (
    tester,
  ) async {
    ignoreUnpaintableThumbnails();
    final source = _FakeShare([for (var i = 0; i < 12; i++) picture('p$i')]);

    await show(tester, bodyFor(tabFor(source)));

    expect(pictures, findsWidgets);
    expect(spinners, findsNothing);
  });

  testWidgets('I1: and again after leaving the grid and coming back', (
    tester,
  ) async {
    ignoreUnpaintableThumbnails();
    final source = _FakeShare([for (var i = 0; i < 12; i++) picture('p$i')]);
    final tab = tabFor(source);

    await show(tester, bodyFor(tab));
    final fetchedFirstTime = source.fetched.length;
    expect(fetchedFirstTime, 12);

    // Away: the tab is showing something else, so this grid is gone.
    await show(tester, const MaterialApp(home: Scaffold(body: Text('x'))));
    await show(tester, bodyFor(tab));

    expect(pictures, findsWidgets);
    expect(spinners, findsNothing);
    // Nothing was asked of the share again: it all came from the cache.
    expect(source.fetched.length, fetchedFirstTime);
  });

  testWidgets('I1: and even if the cache is emptied while away', (
    tester,
  ) async {
    // The regression this pins actually happened: what had been handed out was
    // recorded as answered, so after a cache clear the tiles had no picture,
    // nothing would ask for one again, and a whole tab stayed spinning.
    ignoreUnpaintableThumbnails();
    final source = _FakeShare([for (var i = 0; i < 12; i++) picture('p$i')]);
    final tab = tabFor(source);

    await show(tester, bodyFor(tab));

    await show(tester, const MaterialApp(home: Scaffold(body: Text('x'))));
    await tester.runAsync(() => cacheManager.clearL2()); // empties L1 as well
    await show(tester, bodyFor(tab));

    expect(pictures, findsWidgets);
    expect(spinners, findsNothing);
    expect(source.fetched.length, greaterThan(12), reason: 'fetched again');
  });

  testWidgets('I2: a kind of file with no thumbnail is not asked for twice', (
    tester,
  ) async {
    // Saying "there is no thumbnail for this" is an answer, and repainting the
    // tile must not turn it into another attempt. Only being shown the file
    // itself may (the viewer caches what it read), and that is a separate
    // request — not something ordinary painting does.
    ignoreUnpaintableThumbnails();
    final source = _FakeShare([
      picture('p0'),
      picture('p1'),
    ], unsupported: {'p1'});
    final tab = tabFor(source);

    await show(tester, bodyFor(tab));
    expect(find.byIcon(Icons.archive), findsOneWidget);

    await show(tester, const MaterialApp(home: Scaffold(body: Text('x'))));
    await show(tester, bodyFor(tab));

    expect(find.byIcon(Icons.archive), findsOneWidget);
    expect(source.fetched.where((id) => id == 'p1'), hasLength(1));
  });

  testWidgets('I3: films are captured after pictures, and one at a time', (
    tester,
  ) async {
    // Capturing a frame costs a decoder and a connection of its own, so films
    // wait for the pictures and then queue up behind each other.
    ignoreUnpaintableThumbnails();
    final source = _FakeShare([
      for (var i = 0; i < 6; i++) picture('p$i'),
      film('v0'),
      film('v1'),
      film('v2'),
    ]);

    await show(tester, bodyFor(tabFor(source)));

    final films = ['v0', 'v1', 'v2'];
    final firstFilm = source.fetched.indexWhere(films.contains);
    expect(firstFilm, isNot(-1), reason: 'the films were captured');
    expect(
      source.fetched.sublist(0, firstFilm).toSet(),
      hasLength(6),
      reason: 'every picture was asked for before the first film',
    );
    expect(source.mostAtOnce.films, 1);
  });
}

/// A share that answers instantly and remembers what it was asked for.
class _FakeShare extends SmbSource {
  final List<ImageSource> items;

  /// Ids the share has nothing to make a thumbnail from.
  final Set<String> unsupported;

  /// Every id asked for, in the order it was asked.
  final List<String> fetched = [];

  int _filmsInFlight = 0;
  ({int films}) mostAtOnce = (films: 0);

  _FakeShare(
    this.items, {
    this.unsupported = const {},
  }) : super(
         config: const ServerConfig(
           id: 'test',
           name: 'test',
           type: ImageSourceType.smb,
           host: 'localhost',
         ),
         password: '',
       );

  @override
  Future<List<ImageSource>> listImages({String? path}) async => items;

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    fetched.add(source.id);
    final isFilm = source.metadata?['isVideo'] == true;
    if (isFilm) {
      _filmsInFlight++;
      if (_filmsInFlight > mostAtOnce.films) {
        mostAtOnce = (films: _filmsInFlight);
      }
    }
    try {
      // Yield, so that anything the loader runs in parallel really does
      // overlap here rather than being serialised by a synchronous answer.
      await Future<void>.value();
      if (unsupported.contains(source.id)) {
        throw ThumbnailNotSupportedException(source.name);
      }
      return Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk'
          '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        ),
      );
    } finally {
      if (isFilm) _filmsInFlight--;
    }
  }
}
