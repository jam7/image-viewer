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
import 'package:image_viewer/screens/gallery/widgets/gallery_tab_strip.dart';
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

  testWidgets('tapping the window offers an empty field, not the address',
      (tester) async {
    // Nobody edits an address by hand — places are followed or pasted — and
    // the address is in the menu for taking elsewhere. Showing it here would
    // only be something to delete first.
    await pumpHost(tester);
    expect(inToolbar(find.text('ホーム')), findsOneWidget);

    final field = await startTyping(tester, 'ホーム');

    expect(field.controller!.text, isEmpty);
    expect(field.decoration!.hintText, isNotNull);
  });

  testWidgets('and an empty field submitted asks for nothing', (tester) async {
    await pumpHost(tester);
    await startTyping(tester, 'ホーム');

    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    expect(controller.active!.current.sourceUri, homeGalleryUri());
    expect(controller.active!.history.length, 1);
    expect(inToolbar(find.byType(TextField)), findsNothing); // done editing
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
    // The switch belongs to the search about to be made, so pressing one then
    // submitting searches the other way round.
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

  testWidgets('a switch cannot spoil the place it was pressed on',
      (tester) async {
    // It used to write the option onto the current address, which made an
    // author page into `/user/<id>?s_mode=...` — an address Pixiv reads as an
    // author called "<id>?s_mode=..." and throws on.
    await pumpHost(tester);
    await startTyping(tester, 'ホーム');
    await submit(tester, '${pixivGalleryUri('/user/1700000000000')}');
    await startTyping(tester, '1700000000000 の作品');

    await tester.tap(inToolbar(find.text('完全')));
    await tester.pumpAndSettle();
    await submit(tester, 'books');

    // The option went to the search, and the page it was pressed on is still
    // the plain address it always was.
    final searched = controller.active!.current.sourceUri;
    expect(searched.path, '/search');
    expect(searched.queryParameters['s_mode'], 's_tag');
    final author = controller.active!.history[1].sourceUri;
    expect(author.path, '/user/1700000000000');
    expect(author.hasQuery, isFalse);
  });

  testWidgets('a search offers its word, not its query string', (tester) async {
    // Editing `books` into `books series` should not mean picking the word out
    // of `?word=books&s_mode=...`, where a space is already `%20`.
    await pumpHost(tester);
    await goSomewhere(tester);
    await startTyping(tester, 'Pixiv');
    await submit(tester, 'books');

    final field = await startTyping(tester, 'books');

    expect(field.controller!.text, 'books');
    expect(field.controller!.selection.textInside('books'), 'books');
  });

  testWidgets('the address is still reachable, as its own errand',
      (tester) async {
    // Watching the channel rather than reading the clipboard back: there is no
    // clipboard behind it in a test, and the read never returns.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpHost(tester);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('アドレスをコピー'));
    await tester.pumpAndSettle();

    // Raw, not the friendlier spelling the window offers: this one has to read
    // back as the same place wherever it is pasted.
    expect(copied, ['${homeGalleryUri()}']);
  });

  testWidgets('one tap is enough to start typing, on every source',
      (tester) async {
    // On a Pixiv tab the grid below holds focus for its scroll keys, and a
    // scope that already has a focused child declines an autofocus request —
    // so the first tap opened the field, brought up no keyboard, and left the
    // selection unused until a second tap put the caret at the end.
    await pumpHost(tester);
    await goSomewhere(tester);

    final field = await startTyping(tester, 'Pixiv');

    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.selection,
        TextSelection(baseOffset: 0, extentOffset: field.controller!.text.length));
  });

  testWidgets('no switches where there is no search', (tester) async {
    await pumpHost(tester); // home cannot be searched

    await startTyping(tester, 'ホーム');

    expect(inToolbar(find.text('完全')), findsNothing);
  });

  testWidgets('the page-count filter says so while it is hiding things',
      (tester) async {
    // Forgetting a filter is on and taking a short list for the whole list is
    // the accident this invites, so the number is on the face of the button.
    await pumpHost(tester);
    expect(inToolbar(find.byIcon(Icons.filter_list)), findsNothing); // home
    await goSomewhere(tester); // to Pixiv, whose works have page counts
    expect(inToolbar(find.byIcon(Icons.filter_list)), findsOneWidget);

    await tester.tap(inToolbar(find.byIcon(Icons.filter_list)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3+').last);
    await tester.pumpAndSettle();

    expect(controller.active!.current.minPageCount, 3);
    expect(inToolbar(find.text('3+')), findsOneWidget); // the badge
    expect(inToolbar(find.byIcon(Icons.filter_list)), findsNothing);
  });

  testWidgets('narrowing is per place, so going back finds the list as left',
      (tester) async {
    await pumpHost(tester);
    await goSomewhere(tester);
    controller.active!.current.minPageCount = 5;
    await tester.pumpAndSettle();

    await tester.tap(back());
    await tester.pumpAndSettle();
    expect(inToolbar(find.text('5+')), findsNothing); // home has no such thing

    await tester.tap(forward());
    await tester.pumpAndSettle();

    expect(inToolbar(find.text('5+')), findsOneWidget);
  });

  testWidgets('the two header rows read as one header', (tester) async {
    // Same height was not enough: a chip that filled its row looked taller
    // than the row below, where a 32-high pill floats with margin around it.
    // What has to match is how much of each row is painted.
    await pumpHost(tester);

    final strip = tester.getSize(find.byType(GalleryTabStrip)).height;
    final toolbar = tester.getSize(find.byType(GalleryToolbar)).height;
    expect(strip, toolbar);

    final chip = tester.getSize(find.byType(Tooltip).first).height;
    final window = tester.getSize(inToolbar(find.byType(Container)).first).height;
    expect(chip, lessThan(strip)); // room above it, like the pill below
    expect((chip - window).abs(), lessThanOrEqualTo(4));
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
