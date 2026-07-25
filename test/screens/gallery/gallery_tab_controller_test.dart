import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_tab_controller.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';

/// Tests the set of open tabs: selection, closing, and the rule that the same
/// place may be open more than once (ADR 008).
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late _FakeSource source;
  late GalleryTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('tab_controller_test');
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

  GalleryTab tabAt(String path) => GalleryTab(GallerySession.fromUri(
        smbGalleryUri('srv', path),
        provider: source,
        cacheManager: cache,
      ));

  String pathOf(GalleryTab tab) => smbPathOf(tab.current.sourceUri);

  test('starts empty', () {
    expect(controller.isEmpty, isTrue);
    expect(controller.active, isNull);
  });

  test('opening a tab shows it', () {
    controller.open(tabAt('a'));
    controller.open(tabAt('b'));

    expect(controller.tabs.length, 2);
    expect(controller.activeIndex, 1);
    expect(pathOf(controller.active!), 'b');
  });

  test('the same place can be open twice', () {
    controller.open(tabAt('same'));
    controller.open(tabAt('same'));

    expect(controller.tabs.length, 2);
    expect(controller.tabs[0].id, isNot(controller.tabs[1].id));
  });

  test('selecting switches and notifies', () {
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.open(tabAt('a'));
    controller.open(tabAt('b'));
    notifications = 0;

    controller.select(0);
    expect(pathOf(controller.active!), 'a');
    expect(notifications, 1);

    controller.select(0); // already there
    expect(notifications, 1);

    controller.select(9); // out of range
    expect(notifications, 1);
  });

  test('closing the active tab falls back to its left neighbour', () {
    controller.open(tabAt('a'));
    controller.open(tabAt('b'));
    controller.open(tabAt('c')); // active

    controller.close(2);

    expect(controller.tabs.length, 2);
    expect(pathOf(controller.active!), 'b');
  });

  test('closing a tab left of the active one keeps the same tab showing', () {
    controller.open(tabAt('a'));
    controller.open(tabAt('b'));
    controller.open(tabAt('c'));
    controller.select(2);

    controller.close(0);

    expect(pathOf(controller.active!), 'c');
    expect(controller.activeIndex, 1);
  });

  test('closing the last tab leaves nothing showing', () {
    controller.open(tabAt('only'));

    controller.close(0);

    expect(controller.isEmpty, isTrue);
    expect(controller.active, isNull);
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
