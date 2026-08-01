import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_view.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';

/// Following a link out of the favorites list goes into the tab's history
/// rather than into a new tab, and the destination can belong to another
/// source. That is the first time one tab shows two different bodies, so the
/// handover between them has to be clean.
void main() {
  late Directory tempDir;
  late CacheManager cache;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('cross_source_nav');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 50), l2: l2, l3: l3);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  GallerySession sessionAt(Uri uri) => GallerySession.fromUri(
    uri,
    provider: _FakeSource(),
    cacheManager: cache,
    title: uri.toString(),
  );

  /// Two body widgets of different types over one tab, as the host does when
  /// the scheme of the tab's current entry changes.
  Widget host(GalleryTab tab) => MaterialApp(
    home: AnimatedBuilder(
      animation: tab.revision,
      builder: (context, _) => Scaffold(
        body: tab.current.sourceUri.scheme == favUriScheme
            ? _BodyA(tab: tab)
            : _BodyB(tab: tab),
      ),
    ),
  );

  testWidgets('the session reports to the view that is showing it', (
    tester,
  ) async {
    final favorites = sessionAt(favGalleryUri());
    final tab = GalleryTab(favorites);
    await tester.pumpWidget(host(tab));
    await tester.pumpAndSettle();

    final author = sessionAt(pixivGalleryUri('/user/1'));
    tab.navigate(author);
    await tester.pumpAndSettle();

    // This used to check that the arriving view still held the session's
    // repaint callback: the old body is disposed after the new one is built,
    // and clearing it there left thumbnails arriving with nothing painting
    // them. There is no such callback now — a tile listens for its own
    // thumbnail — so the whole failure mode is gone rather than guarded
    // (ADR 011 段階 3).
    expect(tab.current, author);

    tab.back();
    await tester.pumpAndSettle();

    expect(tab.current, favorites);
  });

  testWidgets('the list stays in the tab history, so back returns to it', (
    tester,
  ) async {
    final favorites = sessionAt(favGalleryUri());
    final tab = GalleryTab(favorites);
    await tester.pumpWidget(host(tab));
    await tester.pumpAndSettle();

    tab.navigate(sessionAt(pixivGalleryUri('/user/1')));
    await tester.pumpAndSettle();
    expect(tab.history.length, 2);
    expect(find.text('B'), findsOneWidget);

    expect(tab.back(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
  });
}

class _BodyA extends StatelessWidget {
  final GalleryTab tab;
  const _BodyA({required this.tab});

  @override
  Widget build(BuildContext context) => GalleryView(
    tab: tab,

    emptyMessage: 'A',
    tileBuilder: (_, item, _) => Text(item.name),
  );
}

class _BodyB extends StatelessWidget {
  final GalleryTab tab;
  const _BodyB({required this.tab});

  @override
  Widget build(BuildContext context) => GalleryView(
    tab: tab,

    emptyMessage: 'B',
    tileBuilder: (_, item, _) => Text(item.name),
  );
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
