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

/// Tests the tab's history stack (ADR 008) — identity separate from place,
/// back/forward, and the browser rule that navigating from mid-history drops
/// what was ahead.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late _FakeSource source;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('gallery_tab_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 200), l2: l2, l3: l3);
    source = _FakeSource();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  GallerySession sessionAt(String path) => GallerySession.fromUri(
        smbGalleryUri('srv', path),
        provider: source,
        cacheManager: cache,
      );

  test('a new tab starts at its one entry', () {
    final tab = GalleryTab(sessionAt('a'));

    expect(tab.index, 0);
    expect(tab.history.length, 1);
    expect(smbPathOf(tab.current.sourceUri), 'a');
    expect(tab.canGoBack, isFalse);
    expect(tab.canGoForward, isFalse);
  });

  test('tabs are told apart by id, not by where they point', () {
    final a = GalleryTab(sessionAt('same'));
    final b = GalleryTab(sessionAt('same'));

    expect(a.id, isNot(b.id));
    // Opening the same place twice is allowed (ADR 008).
    expect(a.current.sourceUri, b.current.sourceUri);
  });

  test('navigating pushes, and back/forward walk the history', () {
    final tab = GalleryTab(sessionAt('a'))
      ..navigate(sessionAt('b'))
      ..navigate(sessionAt('c'));

    expect(tab.index, 2);
    expect(smbPathOf(tab.current.sourceUri), 'c');

    expect(tab.back(), isTrue);
    expect(smbPathOf(tab.current.sourceUri), 'b');
    expect(tab.canGoForward, isTrue);

    expect(tab.back(), isTrue);
    expect(smbPathOf(tab.current.sourceUri), 'a');
    expect(tab.back(), isFalse); // caller's cue to leave the tab
    expect(tab.index, 0);

    expect(tab.forward(), isTrue);
    expect(smbPathOf(tab.current.sourceUri), 'b');
  });

  test('going back keeps the entry loaded, so returning does not refetch',
      () async {
    final tab = GalleryTab(sessionAt('a'));
    await tab.current.loadNextPage();
    expect(source.loadPageCalls, 1);

    tab.navigate(sessionAt('b'));
    await tab.current.loadNextPage();
    expect(source.loadPageCalls, 2);

    tab.back();

    expect(tab.current.loaded.map((i) => i.id), ['a-0']);
    expect(source.loadPageCalls, 2); // came back to a live session
  });

  test('navigating from mid-history drops what was ahead', () {
    final tab = GalleryTab(sessionAt('a'))
      ..navigate(sessionAt('b'))
      ..navigate(sessionAt('c'));
    tab.back(); // at 'b', with 'c' ahead

    tab.navigate(sessionAt('d'));

    expect(tab.history.map((s) => smbPathOf(s.sourceUri)), ['a', 'b', 'd']);
    expect(tab.index, 2);
    expect(tab.canGoForward, isFalse);
  });

  test('replaceCurrent swaps in place instead of adding an entry', () {
    final tab = GalleryTab(sessionAt('a'))..navigate(sessionAt('b'));

    tab.replaceCurrent(sessionAt('b-reloaded'));

    expect(tab.history.map((s) => smbPathOf(s.sourceUri)), ['a', 'b-reloaded']);
    expect(tab.index, 1);
    expect(tab.canGoBack, isTrue); // 'a' is still behind us
  });
}

class _FakeSource extends SmbSource {
  int loadPageCalls = 0;

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
  Future<PageResult> loadPage({String? path, Object? cursor}) async {
    loadPageCalls++;
    return PageResult(items: [
      ImageSource(
        id: '$path-0',
        name: '$path-0',
        uri: '$path-0',
        type: ImageSourceType.smb,
      ),
    ]);
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source,
          {int targetPx = 155}) async =>
      Uint8List.fromList(const [1]);
}
