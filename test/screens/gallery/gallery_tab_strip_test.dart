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

/// Pins what the chips say. A whole SMB path will not fit, so the label is a
/// tail — with one level of parent on the tab being shown, since a leaf alone
/// often cannot tell two tabs apart.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late _FakeSource source;
  late GalleryTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('tab_strip_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 50), l2: l2, l3: l3);
    source = _FakeSource();
    controller = GalleryTabController();
  });

  tearDown(() {
    controller.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  GallerySession smbSession(String path) => GallerySession.fromUri(
        smbGalleryUri('srv', path),
        provider: source,
        cacheManager: cache,
        title: path,
      );

  GallerySession pixivSession(String path, String title) =>
      GallerySession.fromUri(
        pixivGalleryUri(path),
        provider: source,
        cacheManager: cache,
        title: title,
      );

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: GalleryTabStrip(controller: controller),
          body: const SizedBox(),
        ),
      ));

  testWidgets('paths are shown with slashes whatever the source uses',
      (tester) async {
    controller.open(GalleryTab(smbSession(r'books\series\vol2')));

    await pump(tester);

    expect(find.text('series/vol2'), findsOneWidget);
  });

  testWidgets('the shown SMB tab carries its parent, the others do not',
      (tester) async {
    controller.open(GalleryTab(smbSession(r'books\series\vol2\2')));
    controller.open(GalleryTab(smbSession(r'other\deep\inner')));

    await pump(tester);

    expect(find.text('deep/inner'), findsOneWidget); // active
    expect(find.text('2'), findsOneWidget); // background tab: leaf only
  });

  testWidgets('a one-level SMB path does not try to show a parent',
      (tester) async {
    controller.open(GalleryTab(smbSession('books')));

    await pump(tester);

    expect(find.text('books'), findsOneWidget);
  });

  testWidgets('the share root falls back to the server', (tester) async {
    controller.open(GalleryTab(smbSession('/')));

    await pump(tester);

    expect(find.text('srv'), findsOneWidget);
  });

  testWidgets('a Pixiv chip shows the current page title', (tester) async {
    final tab = GalleryTab(pixivSession('/top', 'Pixiv'));
    controller.open(tab);
    await pump(tester);
    expect(find.text('Pixiv'), findsOneWidget);

    // Navigating inside the tab changes what the chip should say.
    tab.navigate(pixivSession('/user/1', 'kazuki の作品'));
    await pump(tester);

    expect(find.text('kazuki の作品'), findsOneWidget);
    expect(find.text('Pixiv'), findsNothing);
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
  Future<Uint8List> fetchThumbnail(ImageSource source,
          {int targetPx = 155}) async =>
      Uint8List.fromList(const [1]);
}
