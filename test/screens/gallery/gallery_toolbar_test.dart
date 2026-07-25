import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_controller.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_opener.dart';
import 'package:image_viewer/screens/gallery/gallery_tabs_screen.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/home_gallery_body.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_toolbar.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/source_registry.dart';
import 'package:image_viewer/services/video/smb_proxy_server.dart';

/// The navigation toolbar (ADR 009). Forward had no input at all before this
/// row existed, and back now has two — the button and the gestures inside the
/// body — which have to mean the same thing.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late SourceRegistry registry;
  late GalleryTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('toolbar');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 20), l2: l2, l3: l3);
    registry = SourceRegistry(smbConfigStore: SmbConfigStore())
      ..register('pixiv:default', _EmptySource());
    controller = GalleryTabController()..open(GalleryTab(homeSession(cache)));
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

  /// Scoped to the toolbar: the tab chip carries the same name, so a bare
  /// text finder cannot tell the two rows apart.
  Finder inToolbar(Finder f) =>
      find.descendant(of: find.byType(GalleryToolbar), matching: f);
  Finder back() => find.widgetWithIcon(IconButton, Icons.arrow_back);
  Finder forward() => find.widgetWithIcon(IconButton, Icons.arrow_forward);
  bool enabled(WidgetTester tester, Finder f) =>
      tester.widget<IconButton>(f).onPressed != null;

  /// Follow the Pixiv card, which navigates within the home tab.
  Future<void> goSomewhere(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(InkWell, 'Pixiv'));
    await tester.pumpAndSettle();
  }

  testWidgets('the toolbar says where the tab is', (tester) async {
    await pumpHost(tester);
    expect(inToolbar(find.text('ホーム')), findsOneWidget);

    await goSomewhere(tester);

    // The chip is short by design, so this is the only place the full name of
    // the current place is shown.
    expect(inToolbar(find.text('Pixiv')), findsOneWidget);
  });

  testWidgets('forward is dead until there is somewhere to go forward to',
      (tester) async {
    await pumpHost(tester);
    expect(enabled(tester, forward()), isFalse);

    await goSomewhere(tester);
    expect(enabled(tester, forward()), isFalse); // at the end of the history

    await tester.tap(back());
    await tester.pumpAndSettle();

    expect(enabled(tester, forward()), isTrue);
  });

  testWidgets('forward returns to the entry back left', (tester) async {
    await pumpHost(tester);
    await goSomewhere(tester);
    await tester.tap(back());
    await tester.pumpAndSettle();
    expect(controller.active!.current.sourceUri.scheme, homeUriScheme);

    await tester.tap(forward());
    await tester.pumpAndSettle();

    expect(controller.active!.current.sourceUri.scheme, pixivUriScheme);
    expect(controller.active!.history.length, 2); // moved, did not re-add
  });

  testWidgets('the back button answers the same as the back gesture',
      (tester) async {
    // Both go through the host, so backing out of a tab closes it either way.
    controller.open(GalleryTab(homeSession(cache)));
    await pumpHost(tester);
    expect(controller.tabs.length, 2);

    await tester.tap(back());
    await tester.pumpAndSettle();

    expect(controller.tabs.length, 1);
  });

  testWidgets('back stays enabled at the first entry', (tester) async {
    // It still does something there: it closes the tab. Greying it out would
    // say otherwise.
    await pumpHost(tester);

    expect(controller.active!.canGoBack, isFalse);
    expect(enabled(tester, back()), isTrue);
  });

  testWidgets('the menu reloads the place without leaving it', (tester) async {
    await pumpHost(tester);
    await goSomewhere(tester);
    final before = controller.active!.current;

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再読み込み'));
    await tester.pumpAndSettle();

    final after = controller.active!.current;
    expect(after, isNot(same(before))); // a fresh session
    expect(after.sourceUri, before.sourceUri); // on the same place
    expect(controller.active!.history.length, 2); // not a new history entry
  });
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
