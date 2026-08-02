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
import 'package:image_viewer/services/video/smb_proxy_server.dart';

/// Long-pressing an author or tag chip means "open it alongside", and tapping
/// one means "go there". Both are handed to the caller now that the viewer is
/// a place in a tab (ADR 010): it no longer closes itself to report anything,
/// and there is no route under it to pop.
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
    void Function(int, String)? onShowAuthor,
    VoidCallback? onClose,
    void Function(bool)? onOverlayChanged,
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
        proxyServer: SmbProxyServer(),
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        onOpenAuthorInNewTab: onAuthor,
        onOpenTagSearchInNewTab: onTag,
        onShowAuthor: onShowAuthor,
        onOverlayChanged: onOverlayChanged,
        onClose: onClose ?? () {},
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
    // The strip is behind the viewer, so say it out loud.
    expect(find.text('新しいタブで開きました: kazuki'), findsOneWidget);
  });

  testWidgets('tapping the author follows it, without leaving', (tester) async {
    // "Go there" used to mean closing the viewer and handing a Map back for
    // the caller to act on. The caller is the tab now, and following a link is
    // something it does itself.
    var followed = 0;
    await pumpViewer(
      tester,
      onAuthor: (_, _) {},
      onShowAuthor: (id, name) => followed++,
    );

    await tester.tap(find.text('kazuki'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(followed, 1);
    expect(find.text('GALLERY_MARKER'), findsNothing); // still here
  });

  testWidgets('everything steps aside after a while, and a tap brings it back',
      (tester) async {
    // Reading is long stretches with no input, and the chrome has no business
    // sitting there through it. The header above goes with it, which is why
    // this is reported rather than kept to the viewer (ADR 010 決定 7).
    final shown = <bool>[];
    await pumpViewer(tester, onOverlayChanged: shown.add);
    expect(shown, [], reason: 'starts shown, so nothing to report yet');

    await tester.pump(const Duration(seconds: 4));
    expect(shown, [false]);

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pump();
    expect(shown, [false, true]);

    // And hides itself again without being asked twice.
    await tester.pump(const Duration(seconds: 4));
    expect(shown, [false, true, false]);
  });

  testWidgets('a page that cannot be read says so, and can be asked again',
      (tester) async {
    // It used to log and leave the spinner turning, which looks exactly like
    // a page still arriving — for as long as the viewer is open.
    final source = _FakeSource()..failReads = true;
    registry.register('smb:test', source);
    await pumpViewer(tester);

    expect(find.text('読み込めませんでした。タップで再試行'), findsOneWidget);

    source.failReads = false;
    await tester.tap(find.byIcon(Icons.broken_image));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('読み込めませんでした。タップで再試行'), findsNothing);
  });

  testWidgets('a chip with nowhere to lead does nothing at all',
      (tester) async {
    // Non-Pixiv content has no author or tag to follow, so the callbacks are
    // null there. Nothing should happen — least of all leaving.
    await pumpViewer(tester);

    await tester.longPress(find.text('kazuki'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('GALLERY_MARKER'), findsNothing);
  });
}

class _FakeSource extends SmbSource {
  /// Whether reading bytes should fail, for the page that says so.
  bool failReads = false;

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
      {void Function(int, int)? onProgress, Size? maxDisplayPx}) async {
    if (failReads) throw Exception('no');
    return Uint8List.fromList(const [1]);
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source,
          {int targetPx = 155}) async =>
      Uint8List.fromList(const [1]);
}
