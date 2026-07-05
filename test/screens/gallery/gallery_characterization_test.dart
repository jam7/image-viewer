import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_screen.dart';
import 'package:image_viewer/screens/gallery/smb_gallery_screen.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/pixiv/pixiv_api_client.dart';
import 'package:image_viewer/services/pixiv/pixiv_web_client.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/pixiv_source.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/sources/source_registry.dart';
import 'package:image_viewer/services/video/smb_proxy_server.dart';

/// Characterization tests: pin down the CURRENT rendering / keyboard / scroll /
/// pop behavior shared by both gallery screens before extracting the common
/// `GalleryGrid` / `GalleryKeyboardScrollable` widgets (see TODO.md gallery
/// unification). They describe what the two screens do today so the extraction
/// can be verified as behavior-preserving.
///
/// Design notes that make these tests possible without network / WebView / SMB:
/// - The fake sources override the page fetch (`listImages` for SMB via the
///   default loadPage; `loadPage` for Pixiv) and `fetchThumbnail` only. Both
///   screens read thumbnails via `CacheManager.get`, which checks the L1 memory
///   cache first, so pre-seeding L1 renders thumbnails through a pure in-memory
///   path (no disk I/O, deterministic under the widget-test fake clock).
/// - The Pixiv gallery is driven through the user-works path (`initialUserPath`)
///   because that branch uses the injected source directly; the default tabbed
///   path creates its own PixivSource from `source.client` and would bypass the
///   fake.
void main() {
  // 1x1 transparent PNG — valid so Image.memory does not raise a decode error.
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  late Directory tempDir;
  late CacheManager cacheManager;
  late FavoritesStore favoritesStore;
  late SourceRegistry registry;
  late SmbProxyServer proxyServer;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('gallery_char_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    // maxEntries large enough that pre-seeded thumbnails are not evicted.
    cacheManager = CacheManager(l1: MemoryCache(maxEntries: 200), l2: l2, l3: l3);
    favoritesStore = FavoritesStore();
    registry = SourceRegistry(smbConfigStore: SmbConfigStore());
    proxyServer = SmbProxyServer();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Seed L1 so every item's thumbnail resolves from memory.
  void seedThumbnails(List<ImageSource> items) {
    for (final item in items) {
      cacheManager.l1.put('thumb:${item.id}', pngBytes);
    }
  }

  List<ImageSource> smbImageItems(int count) => [
        for (var i = 0; i < count; i++)
          ImageSource(
            id: 'f$i',
            name: 'file$i.jpg',
            uri: 'smb://server/share/file$i.jpg',
            type: ImageSourceType.smb,
            sourceKey: 'smb:test',
            metadata: const {},
          ),
      ];

  List<ImageSource> pixivItems(int count) => [
        for (var i = 0; i < count; i++)
          ImageSource(
            id: '$i',
            name: 'artwork$i',
            uri: 'https://i.pximg.net/thumb/$i.jpg',
            type: ImageSourceType.pixiv,
            sourceKey: 'pixiv:default',
            metadata: {
              'illustId': i,
              'thumbnailUrl': 'https://i.pximg.net/thumb/$i.jpg',
              // Odd items are multi-page so the page-count badge is exercised.
              'pageCount': i.isEven ? 1 : 3,
            },
          ),
      ];

  /// Pump [screen] as the home route and flush the async initial load.
  /// Avoids pumpAndSettle because the loading spinner never settles.
  Future<void> pumpHome(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(home: screen));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Push [screen] over a home marker so pop behavior can be asserted.
  Future<GlobalKey<NavigatorState>> pumpPushed(
      WidgetTester tester, Widget screen) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Center(child: Text('HOME_MARKER'))),
    ));
    navKey.currentState!.push(MaterialPageRoute(builder: (_) => screen));
    // Complete the push transition, then flush the load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    return navKey;
  }

  ScrollableState gridScrollState(WidgetTester tester) => tester.state(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );

  /// Send a key, then pump once to run the handler and again to advance the
  /// scroll animation (animateTo runs for 100ms).
  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  // ---------------------------------------------------------------------------
  group('SmbGalleryScreen characterization', () {
    SmbGalleryScreen build(SmbSource source, {String path = '/'}) =>
        SmbGalleryScreen(
          source: source,
          cacheManager: cacheManager,
          favoritesStore: favoritesStore,
          registry: registry,
          proxyServer: proxyServer,
          initialPath: path,
        );

    testWidgets('empty directory shows the not-found message', (tester) async {
      final source = _FakeSmbSource(const []);
      await pumpHome(tester, build(source));
      expect(find.text('ファイルが見つかりませんでした'), findsOneWidget);
    });

    testWidgets('renders one tile per item with thumbnails from cache',
        (tester) async {
      final items = smbImageItems(25);
      seedThumbnails(items);
      final source = _FakeSmbSource(items);
      await pumpHome(tester, build(source));

      // GridView is lazy, so only assert that visible tiles rendered images.
      expect(find.byType(Image), findsWidgets);
      expect(find.byType(GridView), findsOneWidget);
    });

    testWidgets('directory item renders a folder icon tile', (tester) async {
      final items = [
        ImageSource(
          id: 'dir0',
          name: 'subdir',
          uri: 'smb://server/share/subdir',
          type: ImageSourceType.smb,
          sourceKey: 'smb:test',
          metadata: const {'isDirectory': true, 'path': '/subdir'},
        ),
        ...smbImageItems(3),
      ];
      seedThumbnails(items);
      final source = _FakeSmbSource(items);
      await pumpHome(tester, build(source));
      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(find.text('subdir'), findsOneWidget);
    });

    testWidgets('ArrowDown scrolls the grid down; Home returns to top',
        (tester) async {
      final items = smbImageItems(40);
      seedThumbnails(items);
      final source = _FakeSmbSource(items);
      await pumpHome(tester, build(source));

      expect(gridScrollState(tester).position.pixels, 0);

      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      expect(gridScrollState(tester).position.pixels, greaterThan(0));

      await pressKey(tester, LogicalKeyboardKey.home);
      expect(gridScrollState(tester).position.pixels, 0);
    });

    testWidgets('Escape pops the screen', (tester) async {
      // Non-empty: the key handler bails when the grid has no scroll clients.
      final items = smbImageItems(6);
      seedThumbnails(items);
      final navKey = await pumpPushed(tester, build(_FakeSmbSource(items)));
      expect(navKey.currentState!.canPop(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME_MARKER'), findsOneWidget);
    });

    testWidgets('back mouse button pops the screen', (tester) async {
      await pumpPushed(tester, build(_FakeSmbSource(const [])));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppBar)),
        buttons: kBackMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME_MARKER'), findsOneWidget);
    });

    testWidgets('horizontal swipe pops the screen', (tester) async {
      final items = smbImageItems(6);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakeSmbSource(items)));

      await tester.fling(find.byType(GridView), const Offset(300, 0), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME_MARKER'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  group('GalleryScreen (Pixiv, user-works path) characterization', () {
    GalleryScreen build(PixivSource source) => GalleryScreen(
          source: source,
          cacheManager: cacheManager,
          favoritesStore: favoritesStore,
          registry: registry,
          initialUserPath: '/user/123',
          initialUserName: 'test-user',
        );

    testWidgets('empty result shows the not-found message', (tester) async {
      await pumpHome(tester, build(_FakePixivSource(const [])));
      expect(find.text('画像が見つかりませんでした'), findsOneWidget);
    });

    testWidgets('renders tiles and a page-count badge for multi-page works',
        (tester) async {
      final items = pixivItems(25);
      seedThumbnails(items);
      await pumpHome(tester, build(_FakePixivSource(items)));

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      // Multi-page works (odd index) show a layers badge.
      expect(find.byIcon(Icons.layers), findsWidgets);
    });

    testWidgets('ArrowDown scrolls the grid down; Home returns to top',
        (tester) async {
      final items = pixivItems(40);
      seedThumbnails(items);
      await pumpHome(tester, build(_FakePixivSource(items)));

      expect(gridScrollState(tester).position.pixels, 0);

      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      expect(gridScrollState(tester).position.pixels, greaterThan(0));

      await pressKey(tester, LogicalKeyboardKey.home);
      expect(gridScrollState(tester).position.pixels, 0);
    });

    testWidgets('Escape pops the screen', (tester) async {
      // Non-empty: the key handler bails when the grid has no scroll clients.
      final items = pixivItems(6);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakePixivSource(items)));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME_MARKER'), findsOneWidget);
    });

    testWidgets('Backspace pops the screen', (tester) async {
      final items = pixivItems(6);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakePixivSource(items)));

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME_MARKER'), findsOneWidget);
    });
  });
}

/// Fake SMB source: returns canned items and never touches the network.
class _FakeSmbSource extends SmbSource {
  final List<ImageSource> items;
  _FakeSmbSource(this.items)
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
  Future<List<ImageSource>> listImages({String? path}) async => items;

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [0]);
}

/// Fake Pixiv source: returns canned items. The inert client it passes to
/// super is never exercised because listImages / fetchThumbnail are overridden.
class _FakePixivSource extends PixivSource {
  final List<ImageSource> items;
  _FakePixivSource(this.items)
      : super(client: PixivApiClient(webClient: PixivWebClient()));

  // GalleryTab pages via loadPage, so override that (not listImages).
  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async =>
      PageResult(items: items);

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [0]);
}
