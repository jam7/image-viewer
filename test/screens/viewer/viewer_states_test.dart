import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Three times the viewer shows something other than the picture: while it is
/// still working out what the pages are, while a download is in the way, and
/// when it could not open the work at all. They look alike and are not: what
/// the keyboard does differs in each, and Escape in particular means something
/// else during a download than it does anywhere else.
void main() {
  late CacheManager cacheManager;
  late FavoritesStore favoritesStore;
  late SourceRegistry registry;
  late _SlowSource source;

  final work = ImageSource(
    id: '1',
    name: 'work',
    uri: 'https://example.invalid/1.jpg',
    type: ImageSourceType.pixiv,
    sourceKey: 'smb:test',
    metadata: const {'author': 'kazuki', 'authorId': 42},
  );

  setUp(() async {
    final l2 = DiskCache();
    await l2.init(baseDir: Directory.systemTemp.createTempSync('viewer_l2'));
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory.systemTemp.createTempSync('viewer_l3'));
    cacheManager = CacheManager(l1: MemoryCache(maxEntries: 20), l2: l2, l3: l3);
    favoritesStore = FavoritesStore();
    source = _SlowSource();
    registry = SourceRegistry(smbConfigStore: SmbConfigStore())
      ..register('smb:test', source);
  });

  Future<void> pumpViewer(WidgetTester tester, {VoidCallback? onClose}) async {
    await tester.pumpWidget(MaterialApp(
      home: ViewerScreen(
        items: [work],
        registry: registry,
        proxyServer: SmbProxyServer(),
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        onClose: onClose ?? () {},
      ),
    ));
    await tester.pump();
  }

  /// Long enough for the loads to land and the chrome to settle.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('until the pages are known there is only a spinner',
      (tester) async {
    source.pagesGate = Completer<void>();
    await pumpViewer(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('kazuki'), findsNothing, reason: 'no bar over a spinner');

    source.pagesGate!.complete();
    await settle(tester);

    expect(find.text('kazuki'), findsOneWidget);
  });

  testWidgets('a work that will not open offers the way back and nothing else',
      (tester) async {
    // The only screen of the three with a back arrow of its own: the host's
    // toolbar is not over this one, so leaving has to be possible from here.
    source.failPages = true;
    var closed = 0;
    await pumpViewer(tester, onClose: () => closed++);
    await settle(tester);

    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('kazuki'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();

    expect(closed, 1);
  });

  testWidgets('Escape leaves the viewer', (tester) async {
    var closed = 0;
    await pumpViewer(tester, onClose: () => closed++);
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closed, 1);
  });

  testWidgets('but during a download it drops the download, not the viewer',
      (tester) async {
    // Same key, different screen, and the difference matters: a download of a
    // long work is exactly when someone reaches for Escape.
    source.pageCount = 3;
    var closed = 0;
    await pumpViewer(tester, onClose: () => closed++);
    await settle(tester);

    source.readsGate = Completer<void>();
    await tester.tap(find.byIcon(Icons.download));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('kazuki'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closed, 0, reason: 'Escape was for the download');
    expect(find.text('kazuki'), findsOneWidget, reason: 'back to the picture');

    source.readsGate!.complete();
    await settle(tester);
  });
}

/// A source whose answers can be held open, so the screens that only exist
/// while something is in flight can be looked at.
class _SlowSource extends SmbSource {
  int pageCount = 1;
  bool failPages = false;
  Completer<void>? pagesGate;
  Completer<void>? readsGate;

  _SlowSource()
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
  Future<List<ImageSource>> resolvePages(ImageSource source) async {
    await pagesGate?.future;
    if (failPages) throw Exception('no');
    return [
      for (var i = 0; i < pageCount; i++)
        ImageSource(
          id: '${source.id}-$i',
          name: source.name,
          uri: source.uri,
          type: source.type,
          sourceKey: source.sourceKey,
          metadata: source.metadata,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchFullImage(ImageSource source,
      {void Function(int, int)? onProgress}) async {
    await readsGate?.future;
    return Uint8List.fromList(const [1]);
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      Uint8List.fromList(const [1]);
}
