import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/viewer/viewer_screen.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/sources/source_registry.dart';

/// Long-pressing an author or tag chip means "open it alongside". Closing the
/// viewer to do so is the opposite of alongside, so this pins that the viewer
/// stays up and hands the request over instead — and that a plain tap still
/// leaves, which is what "go there" means.
void main() {
  late CacheManager cacheManager;
  late FavoritesStore favoritesStore;
  late SourceRegistry registry;

  final work = ImageSource(
    id: '1',
    name: 'work',
    uri: 'https://example.invalid/1.jpg',
    type: ImageSourceType.pixiv,
    sourceKey: 'smb:test', // resolved by the fake below
    metadata: const {
      'author': 'kazuki',
      'authorId': 42,
      'tags': ['sea', 'summer'],
    },
  );

  setUp(() async {
    final l2 = DiskCache();
    await l2.init(baseDir: Directory.systemTemp.createTempSync('viewer_l2'));
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory.systemTemp.createTempSync('viewer_l3'));
    cacheManager = CacheManager(l1: MemoryCache(maxEntries: 20), l2: l2, l3: l3);
    favoritesStore = FavoritesStore();
    registry = SourceRegistry(smbConfigStore: SmbConfigStore())
      ..register('smb:test', _FakeSource());
  });

  /// Push the viewer over a marker so leaving it can be told from staying.
  Future<void> pumpViewer(
    WidgetTester tester, {
    void Function(int, String)? onAuthor,
    void Function(String)? onTag,
  }) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Center(child: Text('GALLERY_MARKER'))),
    ));
    navKey.currentState!.push(MaterialPageRoute(
      builder: (_) => ViewerScreen(
        items: [work],
        registry: registry,
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        onOpenAuthorInNewTab: onAuthor,
        onOpenTagSearchInNewTab: onTag,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('long-pressing the author hands it over and stays', (tester) async {
    int? gotId;
    String? gotName;
    await pumpViewer(tester, onAuthor: (id, name) {
      gotId = id;
      gotName = name;
    });

    await tester.longPress(find.text('kazuki'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(gotId, 42);
    expect(gotName, 'kazuki');
    expect(find.text('GALLERY_MARKER'), findsNothing); // still in the viewer
  });

  testWidgets('tapping the author still goes there', (tester) async {
    var handedOver = false;
    await pumpViewer(tester, onAuthor: (_, _) => handedOver = true);

    await tester.tap(find.text('kazuki'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(handedOver, isFalse);
    expect(find.text('GALLERY_MARKER'), findsOneWidget); // left the viewer
  });

  testWidgets('with nowhere to put a tab, a long-press falls back to leaving',
      (tester) async {
    await pumpViewer(tester); // no callbacks, as the favorites list pushes it

    await tester.longPress(find.text('kazuki'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('GALLERY_MARKER'), findsOneWidget);
  });
}

class _FakeSource extends SmbSource {
  _FakeSource()
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
  Future<List<ImageSource>> resolvePages(ImageSource source) async => [source];

  @override
  Future<Uint8List> fetchFullImage(ImageSource source,
          {void Function(int, int)? onProgress}) async =>
      Uint8List.fromList(const [1]);

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [1]);
}
