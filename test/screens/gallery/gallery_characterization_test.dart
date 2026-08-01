import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_constants.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_controller.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/pixiv_gallery_body.dart';
import 'package:image_viewer/screens/gallery/smb_gallery_body.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_chrome.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_view.dart';
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
import 'package:image_viewer/widgets/thumbnail_result.dart';

/// Characterization tests: pin down the CURRENT rendering / keyboard / scroll /
/// pop behavior shared by both gallery screens before extracting the common
/// `GalleryGrid` / `GalleryKeyboardScrollable` widgets (see
/// docs/gallery_unification/design.md). They describe what the two screens do
/// today so the extraction can be verified as behavior-preserving.
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

  /// Sessions the body asked to open alongside (long-press).
  final openedInNewTab = <GallerySession>[];

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
    openedInNewTab.clear();
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

  /// Pump [screen] as the home route and flush the async initial load. The
  /// bodies are tab content, so they are wrapped the way the host wraps them.
  /// Avoids pumpAndSettle because the loading spinner never settles.
  Future<void> pumpHome(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
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
    navKey.currentState!.push(
        MaterialPageRoute(builder: (_) => Scaffold(body: screen)));
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
    /// The body under a plain app bar, standing in for the tab strip the host
    /// normally supplies.
    GalleryTab smbTab(SmbSource source, String path) =>
        GalleryTab(GallerySession.fromUri(
          smbGalleryUri(source.config.id, path),
          provider: source,
          cacheManager: cacheManager,
          title: path,
        ));

    /// The tab's content. The app bar belongs to the host, so it is not here.
    SmbGalleryBody build(SmbSource source,
            {String path = '/', GalleryTab? tab}) =>
        SmbGalleryBody(
          tab: tab ?? smbTab(source, path),
          onOpenInNewTab: (s) => openedInNewTab.add(s),
          cacheManager: cacheManager,
          favoritesStore: favoritesStore,
          registry: registry,
          proxyServer: proxyServer,
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

    testWidgets('Escape at the first entry leaves the tab alone',
        (tester) async {
      // Non-empty: the key handler bails when the grid has no scroll clients.
      final items = smbImageItems(6);
      seedThumbnails(items);
      final navKey = await pumpPushed(tester, build(_FakeSmbSource(items)));
      expect(navKey.currentState!.canPop(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Back at the first entry does nothing now: closing a tab is the chip's
      // `x`, never a side effect of navigating, so a double-tap cannot throw
      // away a history that has no undo (ADR 009 追記).
      expect(find.text('HOME_MARKER'), findsNothing);
    });

    testWidgets('the back mouse button leaves the tab alone', (tester) async {
      await pumpPushed(tester, build(_FakeSmbSource(const [])));

      // Anywhere in the tab's content: the app bar is the host's, not the
      // body's, so the mouse-back listener only covers this part.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(GalleryView)),
        buttons: kBackMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Back at the first entry does nothing now: closing a tab is the chip's
      // `x`, never a side effect of navigating, so a double-tap cannot throw
      // away a history that has no undo (ADR 009 追記).
      expect(find.text('HOME_MARKER'), findsNothing);
    });

    testWidgets('a horizontal swipe leaves the tab alone', (tester) async {
      final items = smbImageItems(6);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakeSmbSource(items)));

      await tester.fling(find.byType(GridView), const Offset(300, 0), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Back at the first entry does nothing now: closing a tab is the chip's
      // `x`, never a side effect of navigating, so a double-tap cannot throw
      // away a history that has no undo (ADR 009 追記).
      expect(find.text('HOME_MARKER'), findsNothing);
    });

    // -- Tab history (ADR 008, phase 2B-9) --------------------------------

    /// A directory holding one subdirectory, whose own listing has one file.
    _FakeSmbSource nestedSource() {
      final dir = ImageSource(
        id: 'dir0',
        name: 'subdir',
        uri: 'smb://server/share/subdir',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
        metadata: const {'isDirectory': true, 'path': 'subdir'},
      );
      final inner = ImageSource(
        id: 'inner0',
        name: 'inner.jpg',
        uri: 'smb://server/share/subdir/inner.jpg',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
        metadata: const {},
      );
      seedThumbnails([inner]);
      return _FakeSmbSource([dir], byPath: {'subdir': [inner]});
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('a directory opens in the same tab, not a new screen',
        (tester) async {
      final source = nestedSource();
      final tab = smbTab(source, '/');
      await pumpPushed(tester, build(source, tab: tab));
      expect(find.text('subdir'), findsOneWidget); // the folder tile
      expect(tab.history.length, 1);

      await tester.tap(find.text('subdir'));
      await settle(tester);

      // Descended within the one tab: history grew, no second body appeared,
      // and the folder tile gave way to the subdirectory's contents.
      expect(tab.history.length, 2);
      expect(tab.index, 1);
      expect(smbPathOf(tab.current.sourceUri), 'subdir');
      expect(find.byType(SmbGalleryBody), findsOneWidget);
      expect(find.text('subdir'), findsNothing);
    });

    testWidgets('back from a subdirectory returns to its parent, not out',
        (tester) async {
      await pumpPushed(tester, build(nestedSource()));
      await tester.tap(find.text('subdir'));
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      // Back in the parent listing, still inside the gallery.
      expect(find.text('HOME_MARKER'), findsNothing);
      expect(find.text('subdir'), findsOneWidget); // the parent's tile again
    });

    testWidgets('back at the first entry keeps the tab and its history',
        (tester) async {
      final tab = smbTab(nestedSource(), '/');
      await pumpPushed(tester, build(nestedSource(), tab: tab));
      await tester.tap(find.text('subdir'));
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape); // to parent
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape); // nowhere to go
      await tester.pump(const Duration(milliseconds: 400));

      // Back at the first entry does nothing now: closing a tab is the chip's
      // `x`, never a side effect of navigating, so a double-tap cannot throw
      // away a history that has no undo (ADR 009 追記).
      expect(find.text('HOME_MARKER'), findsNothing);
      // And forward still works, which is the point of not discarding it.
      expect(tab.history.length, 2);
      expect(tab.canGoForward, isTrue);
    });

    testWidgets('returning to a visited directory does not refetch it',
        (tester) async {
      final source = nestedSource();
      await pumpPushed(tester, build(source));
      await tester.tap(find.text('subdir'));
      await settle(tester);
      final listingsAfterDescent = source.listCalls;

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      // The parent's session was kept alive in the history.
      expect(source.listCalls, listingsAfterDescent);
    });

    testWidgets('coming back restores where the parent was scrolled to',
        (tester) async {
      // A parent long enough to scroll, with the subdirectory partway down so
      // it is still on screen once we have scrolled.
      final dir = ImageSource(
        id: 'dir0',
        name: 'subdir',
        uri: 'smb://server/share/subdir',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
        metadata: const {'isDirectory': true, 'path': 'subdir'},
      );
      final files = smbImageItems(60);
      final inner = smbImageItems(3);
      seedThumbnails([...files, ...inner]);
      final parent = [...files.take(20), dir, ...files.skip(20)];
      final source = _FakeSmbSource(parent, byPath: {'subdir': inner});

      await pumpPushed(tester, build(source));
      final scroll = gridScrollState(tester);
      scroll.position.jumpTo(galleryRowStride(800) * 3);
      await tester.pump();
      final before = scroll.position.pixels;
      expect(before, greaterThan(0));
      expect(find.text('subdir'), findsOneWidget); // still on screen

      // Down into the subdirectory...
      await tester.tap(find.text('subdir'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // ...and back out.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(gridScrollState(tester).position.pixels, closeTo(before, 1.0));
    });

    testWidgets('a newly opened directory starts at the top', (tester) async {
      final dir = ImageSource(
        id: 'dir0',
        name: 'subdir',
        uri: 'smb://server/share/subdir',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
        metadata: const {'isDirectory': true, 'path': 'subdir'},
      );
      final files = smbImageItems(60);
      final inner = smbImageItems(60);
      seedThumbnails([...files, ...inner]);
      final source = _FakeSmbSource([...files.take(20), dir, ...files.skip(20)],
          byPath: {'subdir': inner});

      await pumpPushed(tester, build(source));
      gridScrollState(tester).position.jumpTo(galleryRowStride(800) * 3);
      await tester.pump();

      await tester.tap(find.text('subdir'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The subdirectory is long enough to hold the parent's offset, so this
      // fails if the shared controller simply keeps its position.
      expect(gridScrollState(tester).position.pixels, 0);
    });

    testWidgets('thumbnails appear on a session nobody wired a callback to',
        (tester) async {
      // Tabs made by the opener carry no repaint callback — the view showing
      // the session installs one. Without that, every tile spins forever even
      // though the results have arrived.
      final items = smbImageItems(4);
      seedThumbnails(items);
      final source = _FakeSmbSource(items);
      final tab = smbTab(source, '/');

      await pumpPushed(tester, build(source, tab: tab));

      expect(tab.current.thumbnailFor(items.first), isA<ThumbnailData>());
      expect(find.byType(Image), findsWidgets); // painted, not still spinning
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('closing the tab being shown does not blow up the teardown',
        (tester) async {
      // Closing disposes the tab's history, so anything that then asks the tab
      // for its current entry throws — which is exactly what the view's
      // deactivate used to do on the way out.
      final items = smbImageItems(4);
      seedThumbnails(items);
      final source = _FakeSmbSource(items);
      final tab = smbTab(source, '/');
      final controller = GalleryTabController()..open(tab);
      addTearDown(controller.dispose);

      await pumpPushed(tester, build(source, tab: tab));

      controller.close(0);
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Center(child: Text('HOME_MARKER')))));
      await settle(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('long-pressing a folder asks for it alongside, not instead',
        (tester) async {
      final source = nestedSource();
      final tab = smbTab(source, '/');
      await pumpPushed(tester, build(source, tab: tab));

      await tester.longPress(find.text('subdir'));
      await settle(tester);

      // Asked for a second tab, and stayed where it was.
      expect(openedInNewTab.length, 1);
      expect(smbPathOf(openedInNewTab.single.sourceUri), 'subdir');
      expect(tab.history.length, 1);
      expect(smbPathOf(tab.current.sourceUri), '/');
      expect(find.text('subdir'), findsOneWidget); // the folder tile, still
    });

    testWidgets('a mostly-vertical flick does not pop a short list',
        (tester) async {
      // Few enough items that the grid has nothing to scroll. Flutter's default
      // physics then refuse the drag, which used to hand a slightly diagonal
      // vertical flick to the swipe-back recognizer.
      final items = smbImageItems(5);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakeSmbSource(items)));

      // dx=100 against dy=300 is about 18 degrees off vertical, the shallowest
      // deviation that reached the swipe-back recognizer before the fix.
      await tester.fling(find.byType(GridView), const Offset(100, -300), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('HOME_MARKER'), findsNothing); // still in the directory
    });
  });

  // ---------------------------------------------------------------------------
  group('GalleryScreen (Pixiv, user-works path) characterization', () {
    PixivGalleryBody build(PixivSource source) => PixivGalleryBody(
          tab: GalleryTab(GallerySession.fromUri(
            pixivGalleryUri('/user/123'),
            provider: source,
            cacheManager: cacheManager,
            title: 'test-user の作品',
          )),
          onOpenInNewTab: (s) => openedInNewTab.add(s),
          cacheManager: cacheManager,
          favoritesStore: favoritesStore,
          registry: registry,
        );

    // The section menu used to live in this body's own header. It is the
    // toolbar's hamburger now (2C-3), and is characterized there instead.

    testWidgets('"N+" hides the works with fewer than N pages', (tester) async {
      // The fixture alternates 1-page and 3-page works. 3+ keeps exactly the
      // 3-page ones: the boundary is *at least* N, which is how a button
      // labelled 3+ reads. It used to mean more than N, which a text box
      // reading ">N" got away with.
      final items = pixivItems(6);
      seedThumbnails(items);
      final body = build(_FakePixivSource(items));
      await pumpHome(tester, body);
      expect(tester.widgetList(find.byType(Image)).length, 6);

      // As the toolbar does it: set it on the place, then rebuild the body.
      body.tab.current.minPageCount = 3;
      await pumpHome(tester, PixivGalleryBody(
        tab: body.tab,
        onOpenInNewTab: body.onOpenInNewTab,
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        registry: registry,
      ));

      expect(tester.widgetList(find.byType(Image)).length, 3);
      expect(body.tab.current.loaded.length, 6); // narrowed, not refetched
    });

    testWidgets('scrolling the grid folds the header away and back',
        (tester) async {
      // The wiring, not the rule: the view has to find the shared say-so
      // through the tree and actually set it while the list moves.
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final items = pixivItems(60);
      seedThumbnails(items);
      await pumpHome(
        tester,
        GalleryChrome(
          visible: visible,
          child: build(_FakePixivSource(items)),
        ),
      );
      expect(visible.value, isTrue);

      await tester.drag(find.byType(GridView), const Offset(0, -300));
      await tester.pump();
      expect(visible.value, isFalse);

      await tester.drag(find.byType(GridView), const Offset(0, 120));
      await tester.pump();
      expect(visible.value, isTrue);
    });

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

    testWidgets('Escape at the first entry leaves the tab alone',
        (tester) async {
      // Non-empty: the key handler bails when the grid has no scroll clients.
      final items = pixivItems(6);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakePixivSource(items)));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Back at the first entry does nothing now: closing a tab is the chip's
      // `x`, never a side effect of navigating, so a double-tap cannot throw
      // away a history that has no undo (ADR 009 追記).
      expect(find.text('HOME_MARKER'), findsNothing);
    });

    testWidgets('Backspace at the first entry leaves the tab alone',
        (tester) async {
      final items = pixivItems(6);
      seedThumbnails(items);
      await pumpPushed(tester, build(_FakePixivSource(items)));

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Back at the first entry does nothing now: closing a tab is the chip's
      // `x`, never a side effect of navigating, so a double-tap cannot throw
      // away a history that has no undo (ADR 009 追記).
      expect(find.text('HOME_MARKER'), findsNothing);
    });
  });
}

/// Fake SMB source: returns canned items and never touches the network.
class _FakeSmbSource extends SmbSource {
  final List<ImageSource> items;

  /// Listings for paths other than the initial one, so a directory tap has
  /// somewhere to go.
  final Map<String, List<ImageSource>> byPath;

  _FakeSmbSource(this.items, {this.byPath = const {}})
      : super(
          config: const ServerConfig(
            id: 'test',
            name: 'test',
            type: ImageSourceType.smb,
            host: 'localhost',
          ),
          password: '',
        );

  int listCalls = 0;

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    listCalls++;
    return byPath[path] ?? items;
  }

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

  // GallerySession pages via loadPage, so override that (not listImages).
  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async =>
      PageResult(items: items);

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [0]);
}
