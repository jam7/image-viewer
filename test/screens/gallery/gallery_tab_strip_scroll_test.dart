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
import 'package:image_viewer/screens/gallery/widgets/gallery_tab_strip.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';

/// With enough tabs to overflow, the strip scrolls — and switching tabs rebuilds
/// the body it lives in, so its position has to survive that or every switch
/// snaps the strip back to the first tab.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late _FakeSource source;
  late GalleryTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('strip_scroll_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 20), l2: l2, l3: l3);
    source = _FakeSource();
    controller = GalleryTabController();
    for (var i = 0; i < 12; i++) {
      controller.open(GalleryTab(GallerySession.fromUri(
        smbGalleryUri('srv', 'folder$i'),
        provider: source,
        cacheManager: cache,
        title: 'folder$i',
      )));
    }
  });

  tearDown(() {
    controller.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Mirrors the host: one Scaffold whose app bar is the strip, with a body
  /// keyed per tab so switching rebuilds it.
  Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => Scaffold(
            appBar: GalleryTabStrip(controller: controller),
            body: SizedBox(key: ValueKey(controller.active!.id)),
          ),
        ),
      ));

  GalleryTab newTab(String path) => GalleryTab(GallerySession.fromUri(
        smbGalleryUri('srv', path),
        provider: source,
        cacheManager: cache,
        title: path,
      ));

  ScrollableState stripScroll(WidgetTester tester) => tester.state(
        find.descendant(
          of: find.byType(GalleryTabStrip),
          matching: find.byType(Scrollable),
        ),
      );

  testWidgets('switching tabs leaves the strip where it was scrolled to',
      (tester) async {
    await pump(tester);
    stripScroll(tester).position.jumpTo(120);
    await tester.pump();
    expect(stripScroll(tester).position.pixels, 120);

    controller.select(3);
    await tester.pump();
    await tester.pump();

    expect(stripScroll(tester).position.pixels, 120);
  });

  testWidgets('opening a tab scrolls the strip to show it', (tester) async {
    await pump(tester);
    final scroll = stripScroll(tester);
    scroll.position.jumpTo(0); // looking at the left end
    await tester.pump();

    // Opened in the background, as a long-press does: nothing else would tell
    // the user it happened.
    controller.open(newTab('brand-new'), activate: false);
    await tester.pump(); // build, then the post-frame callback starts the scroll
    await tester.pump(); // the animation's ticker takes its start time here
    await tester.pumpAndSettle();

    final after = stripScroll(tester);
    expect(after.position.pixels, after.position.maxScrollExtent);
    expect(after.position.pixels, greaterThan(0));
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

  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async =>
      const PageResult(items: []);

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [1]);
}
