import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_controller.dart';
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

/// The system back gesture has to walk the tab's history like every other back
/// affordance, including right after switching to that tab — the body is
/// rebuilt then, and with it the PopScope that decides whether the gesture is
/// ours to handle.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late FavoritesStore favoritesStore;
  late SourceRegistry registry;
  late SmbProxyServer proxyServer;
  late _FakeSource source;
  late GalleryTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('back_after_switch');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 50), l2: l2, l3: l3);
    favoritesStore = FavoritesStore();
    registry = SourceRegistry(smbConfigStore: SmbConfigStore());
    proxyServer = SmbProxyServer();
    source = _FakeSource();
    controller = GalleryTabController();
  });

  tearDown(() {
    controller.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  GallerySession sessionAt(String path) => GallerySession.fromUri(
        smbGalleryUri('srv', path),
        provider: source,
        cacheManager: cache,
        title: path,
      );

  /// The host: one Scaffold, body keyed per tab.
  Future<void> pumpHost(WidgetTester tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Center(child: Text('HOME_MARKER'))),
    ));
    navKey.currentState!.push(MaterialPageRoute(
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final tab = controller.active!;
          return AnimatedBuilder(
            animation: tab.revision,
            builder: (context, _) => Scaffold(
              body: SmbGalleryBody(
                key: ValueKey(tab.id),
                tab: tab,
                onOpenInNewTab: (_) {},
                cacheManager: cache,
                favoritesStore: favoritesStore,
                registry: registry,
                proxyServer: proxyServer,
              ),
            ),
          );
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('system back walks the history of the tab just switched to',
      (tester) async {
    final deep = GalleryTab(sessionAt('a'))..navigate(sessionAt(r'a\inner'));
    controller.open(deep);
    controller.open(GalleryTab(sessionAt('fresh'))); // active, no history
    await pumpHost(tester);

    controller.select(0); // switch to the tab that has history
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(smbPathOf(controller.active!.current.sourceUri), r'a\inner');

    await systemBack(tester);

    expect(find.text('HOME_MARKER'), findsNothing); // did not leave the gallery
    expect(smbPathOf(controller.active!.current.sourceUri), 'a');
  });

  testWidgets('history made by tapping, then switched away and back',
      (tester) async {
    // Closer to how it is actually done: descend in the UI, look at another
    // tab, come back, then press back.
    final dir = ImageSource(
      id: 'dir0',
      name: 'subdir',
      uri: 'smb://srv/subdir',
      type: ImageSourceType.smb,
      sourceKey: 'smb:srv',
      metadata: const {'isDirectory': true, 'path': 'subdir'},
    );
    source.listings['/'] = [dir];
    source.listings['subdir'] = const [];

    final browsing = GalleryTab(sessionAt('/'));
    controller.open(browsing);
    controller.open(GalleryTab(sessionAt('other')));
    controller.select(0);
    await pumpHost(tester);

    await tester.tap(find.text('subdir'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(browsing.history.length, 2);

    controller.select(1); // look at the other tab
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    controller.select(0); // and back
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await systemBack(tester);

    expect(find.text('HOME_MARKER'), findsNothing);
    expect(browsing.index, 0);
  });

  testWidgets('the system gesture goes to the OS at a tab\'s first entry',
      (tester) async {
    // Nothing left to walk, so the route pops -- in the app this screen is the
    // root, which is Android backgrounding the app. It does not close the tab.
    controller.open(GalleryTab(sessionAt('only')));
    await pumpHost(tester);

    await systemBack(tester);

    expect(find.text('HOME_MARKER'), findsOneWidget);
    expect(controller.tabs.length, 1);
  });

  testWidgets('backing out of a tab never closes it', (tester) async {
    // Back is navigation. Discarding a tab -- and a history with no undo --
    // takes the chip's `x` (ADR 009 追記).
    controller.open(GalleryTab(sessionAt('first')));
    controller.open(GalleryTab(sessionAt('opened'))); // active, no history
    await pumpHost(tester);

    await systemBack(tester);

    expect(controller.tabs.length, 2);
    expect(smbPathOf(controller.active!.current.sourceUri), 'opened');
  });

  testWidgets('history is walked to the end, and then kept', (tester) async {
    final tab = GalleryTab(sessionAt('a'))..navigate(sessionAt(r'a\inner'));
    controller.open(tab);
    await pumpHost(tester);

    await systemBack(tester);
    expect(smbPathOf(tab.current.sourceUri), 'a');

    await systemBack(tester); // no history left: the OS gets it
    expect(find.text('HOME_MARKER'), findsOneWidget);

    // The tab and the entry back left are both still there.
    expect(controller.tabs.length, 1);
    expect(tab.history.length, 2);
    expect(tab.canGoForward, isTrue);
  });
}

class _FakeSource extends SmbSource {
  _FakeSource()
      : super(
          config: const ServerConfig(
            id: 'srv',
            name: 'srv',
            type: ImageSourceType.smb,
            host: 'localhost',
          ),
          password: '',
        );

  final Map<String, List<ImageSource>> listings = {};

  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async =>
      PageResult(items: listings[path] ?? const []);

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [1]);
}
