import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('back goes dead at the first entry rather than closing the tab',
      (tester) async {
    // Discarding a tab, and a history that has no undo, is the chip's `x`.
    // A greyed-out button says "nothing here" without being able to destroy
    // anything when it is tapped twice (ADR 009 追記).
    controller.open(GalleryTab(homeSession(cache)));
    await pumpHost(tester);
    expect(controller.tabs.length, 2);

    expect(controller.active!.canGoBack, isFalse);
    expect(enabled(tester, back()), isFalse);
    expect(controller.tabs.length, 2);
  });

  testWidgets('back and forward light up with the history', (tester) async {
    await pumpHost(tester);
    expect(enabled(tester, back()), isFalse);

    await goSomewhere(tester);
    expect(enabled(tester, back()), isTrue);

    await tester.tap(back());
    await tester.pumpAndSettle();

    expect(enabled(tester, back()), isFalse);
    expect(enabled(tester, forward()), isTrue);
  });

  /// Tap the window and get at the field it turns into.
  Future<TextField> startTyping(WidgetTester tester, String shownNow) async {
    await tester.tap(inToolbar(find.text(shownNow)));
    await tester.pumpAndSettle();
    return tester.widget<TextField>(inToolbar(find.byType(TextField)));
  }

  Future<void> submit(WidgetTester tester, String text) async {
    await tester.enterText(inToolbar(find.byType(TextField)), text);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  testWidgets('tapping the window offers the address, selected whole',
      (tester) async {
    // The address is the thing worth taking elsewhere, and handing it over
    // selected is the whole of "copy this place" — no feature of ours needed.
    await pumpHost(tester);
    expect(inToolbar(find.text('ホーム')), findsOneWidget);

    final field = await startTyping(tester, 'ホーム');

    expect(field.controller!.text, '${homeGalleryUri()}');
    expect(field.controller!.selection,
        TextSelection(baseOffset: 0, extentOffset: field.controller!.text.length));
  });

  testWidgets('an address goes there, in this tab', (tester) async {
    await pumpHost(tester);
    await startTyping(tester, 'ホーム');

    await submit(tester, '${pixivGalleryUri('/bookmarks')}');

    final tab = controller.active!;
    expect(tab.current.sourceUri.path, '/bookmarks');
    expect(tab.history.length, 2); // pushed, so back comes home
    expect(controller.tabs.length, 1); // and not a second tab
  });

  testWidgets('anything else is a search of the source we are on',
      (tester) async {
    await pumpHost(tester);
    await goSomewhere(tester); // to Pixiv, which has a search
    await startTyping(tester, 'Pixiv');

    await submit(tester, 'books');

    final uri = controller.active!.current.sourceUri;
    expect(uri.path, '/search');
    expect(uri.queryParameters['word'], 'books');
  });

  testWidgets('a half-typed address searches rather than complaining',
      (tester) async {
    // Hitting enter partway through `smb://` is a normal accident. Searching
    // for it is recoverable; an error dialog would be in the way.
    await pumpHost(tester);
    await goSomewhere(tester);
    await startTyping(tester, 'Pixiv');

    await submit(tester, 'smb://');

    expect(controller.active!.current.sourceUri.path, '/search');
  });

  testWidgets('a source with no search drops what was typed', (tester) async {
    await pumpHost(tester);
    final before = controller.active!.current.sourceUri;
    await startTyping(tester, 'ホーム'); // home cannot be searched

    await submit(tester, 'books');

    expect(controller.active!.current.sourceUri, before);
    expect(controller.active!.history.length, 1);
    expect(inToolbar(find.byType(TextField)), findsNothing); // back to showing
  });

  testWidgets('escape abandons the edit and shows where we still are',
      (tester) async {
    await pumpHost(tester);
    await startTyping(tester, 'ホーム');
    await tester.enterText(inToolbar(find.byType(TextField)), 'books');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(inToolbar(find.byType(TextField)), findsNothing);
    expect(inToolbar(find.text('ホーム')), findsOneWidget);
    expect(controller.active!.history.length, 1);
  });

  testWidgets("the menu carries the source's own sections", (tester) async {
    // They were in the Pixiv body's header until 2C-3. Up here they work the
    // same for every source, and the body no longer needs a header at all.
    await pumpHost(tester);
    await goSomewhere(tester); // to Pixiv

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('ブックマーク'), findsOneWidget);
    // Cross-source favorites are not a Pixiv section; they are a `+` entry.
    expect(find.text('お気に入り'), findsNothing);
    await tester.tap(find.text('ブックマーク'));
    await tester.pumpAndSettle();

    expect(controller.active!.current.sourceUri.path, '/bookmarks');
    expect(controller.active!.history.length, 3); // pushed, not a new tab
  });

  testWidgets('a source with no sections gets only the common entries',
      (tester) async {
    await pumpHost(tester); // home

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('ブックマーク'), findsNothing);
    expect(find.text('再読み込み'), findsOneWidget);
  });

  testWidgets('the search switches show while typing, and travel', (tester) async {
    // The switch reads off the address and writes back to it, so pressing one
    // then submitting re-runs the search the other way round.
    await pumpHost(tester);
    await goSomewhere(tester);
    await startTyping(tester, 'Pixiv');
    expect(inToolbar(find.text('完全')), findsOneWidget);

    await tester.tap(inToolbar(find.text('完全')));
    await tester.pumpAndSettle();
    expect(inToolbar(find.text('部分')), findsOneWidget); // now reads the new way

    await submit(tester, 'books');

    expect(controller.active!.current.sourceUri.queryParameters['s_mode'],
        's_tag');
  });

  testWidgets('no switches where there is no search', (tester) async {
    await pumpHost(tester); // home cannot be searched

    await startTyping(tester, 'ホーム');

    expect(inToolbar(find.text('完全')), findsNothing);
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
