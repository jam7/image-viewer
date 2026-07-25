import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_controller.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_opener.dart';
import 'package:image_viewer/screens/gallery/gallery_tabs_screen.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/home_gallery_body.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/source_registry.dart';
import 'package:image_viewer/services/video/smb_proxy_server.dart';

/// Home is a tab now, and the app's root is the tab host — so the landing page
/// follows the same rules as everywhere else: a tap is a link into this tab's
/// history, a long press opens alongside, and back never leaves you nowhere.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late SourceRegistry registry;
  late GalleryTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('home_tab');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 20), l2: l2, l3: l3);
    registry = SourceRegistry(smbConfigStore: SmbConfigStore());
    // Stands in for a signed-in Pixiv, so tapping the card actually resolves.
    registry.register('pixiv:default', _EmptySource());
    controller = GalleryTabController()
      ..open(GalleryTab(homeSession(cache)));
  });

  tearDown(() {
    controller.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: GalleryTabsScreen(
        controller: controller,
        opener: GalleryTabOpener(
          registry: registry,
          cacheManager: cache,
          favoritesStore: FavoritesStore(),
        ),
        smbConfigStore: SmbConfigStore(),
        proxyServer: SmbProxyServer(),
        cacheManager: cache,
        favoritesStore: FavoritesStore(),
        registry: registry,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Finder pixivCard() => find.widgetWithText(InkWell, 'Pixiv');

  testWidgets('the app starts on a home tab', (tester) async {
    await pumpHost(tester);

    expect(find.text('サービス'), findsOneWidget);
    expect(find.text('サーバー'), findsOneWidget);
    // What is out there to reach, then what is already yours, then the one
    // entry that is not a destination at all.
    expect(find.text('ライブラリ'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '設定'), findsOneWidget);
    expect(controller.tabs.length, 1);
    expect(controller.active!.current.sourceUri.scheme, homeUriScheme);
  });

  testWidgets('the favorites shortcut opens the list in this tab',
      (tester) async {
    registry.register('fav:default', _EmptySource());
    await pumpHost(tester);

    await tester.tap(find.widgetWithText(InkWell, 'お気に入り'));
    await tester.pumpAndSettle();

    expect(controller.tabs.length, 1);
    expect(controller.active!.current.sourceUri.scheme, favUriScheme);
  });

  testWidgets('tapping a service follows it in this tab', (tester) async {
    await pumpHost(tester);

    await tester.tap(pixivCard());
    await tester.pumpAndSettle();

    expect(controller.tabs.length, 1); // no second tab
    expect(controller.active!.history.length, 2);
    expect(controller.active!.current.sourceUri.scheme, pixivUriScheme);
  });

  testWidgets('long-pressing a service opens it alongside', (tester) async {
    await pumpHost(tester);

    await tester.longPress(pixivCard());
    await tester.pumpAndSettle();

    expect(controller.tabs.length, 2);
    expect(controller.active!.current.sourceUri.scheme, homeUriScheme);
  });

  testWidgets('back returns to home within the tab', (tester) async {
    await pumpHost(tester);
    await tester.tap(pixivCard());
    await tester.pumpAndSettle();

    await systemBack(tester);

    expect(controller.active!.current.sourceUri.scheme, homeUriScheme);
    expect(find.text('サービス'), findsOneWidget);
  });

  testWidgets('backing out of the last tab lands on home, not nowhere',
      (tester) async {
    // There is no route under the tab host any more, so "leave the gallery"
    // has to mean something else.
    controller.close(0);
    controller.open(GalleryTab(await _pixivSession(registry, cache)));
    await pumpHost(tester);
    expect(controller.active!.current.sourceUri.scheme, pixivUriScheme);

    await systemBack(tester);

    expect(controller.tabs.length, 1);
    expect(controller.active!.current.sourceUri.scheme, homeUriScheme);
  });

  testWidgets('back on the lone home tab is left to the system',
      (tester) async {
    await pumpHost(tester);

    await systemBack(tester);

    // Nothing swallowed it and nothing was destroyed: still home, still open.
    expect(controller.tabs.length, 1);
    expect(controller.active!.current.sourceUri.scheme, homeUriScheme);
  });
}

Future<GallerySession> _pixivSession(
    SourceRegistry registry, CacheManager cache) async {
  final opener = GalleryTabOpener(
    registry: registry,
    cacheManager: cache,
    favoritesStore: FavoritesStore(),
  );
  return (await opener.session(pixivGalleryUri('/top'), _NoContext()))!;
}

/// resolve takes a BuildContext only to raise a login screen, which a
/// registered source never needs.
class _NoContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _EmptySource extends ImageSourceProvider {
  @override
  Future<List<ImageSource>> listImages({String? path}) async => const [];

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) =>
      throw ThumbnailNotSupportedException('none');

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) =>
      throw UnsupportedError('none');

  @override
  Future<void> dispose() async {}
}
