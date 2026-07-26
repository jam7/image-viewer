import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_chrome.dart';

/// When the two header rows fold away (ADR 009, 2C-5). The rule is separate
/// from the widget so the awkward parts — the wobble of a finger, arriving
/// part-way down a list — can be tried without a viewport.
void main() {
  late ChromeScrollRule rule;

  setUp(() => rule = ChromeScrollRule());

  /// The verdict after scrolling to [offset]; null means "no change".
  bool? scrollTo(double offset) =>
      rule.update(offset, atTop: offset <= 0);

  test('arriving part-way down a list is not reading forward', () {
    // A revisited place opens where it was left, which may be far down. The
    // distance is measured from there, not from the top of a list nobody
    // scrolled through.
    expect(scrollTo(4000), isNull); // showing already; nothing to change
    expect(scrollTo(4010), isNull);

    expect(scrollTo(4400), isFalse);
  });

  test('reading forward folds it away, once it is really reading', () {
    scrollTo(0);
    expect(scrollTo(10), isNull); // a finger resting, not a scroll
    expect(scrollTo(20), isNull);

    expect(scrollTo(400), isFalse);
    expect(scrollTo(800), isNull); // already gone, nothing to say
  });

  test('and any move back brings it straight out', () {
    scrollTo(0);
    scrollTo(400);

    // No threshold on the way back: waiting is what makes a header feel
    // reluctant, and the reader who scrolls up is looking for it.
    expect(scrollTo(396), isTrue);
  });

  test('the top always shows it', () {
    scrollTo(0);
    scrollTo(400);
    expect(scrollTo(0), isTrue);
  });

  test('turning round mid-list starts the distance again', () {
    scrollTo(0);
    scrollTo(400); // hidden
    scrollTo(390); // shown, and this is the new mark

    expect(scrollTo(410), isNull); // 20 forward of the turn: not yet
    expect(scrollTo(430), isFalse);
  });

  group('what the header does on arriving somewhere', () {
    // These were only ever checked by hand on a device, because the rules
    // lived on the screen. They decide when the system bars come off, which
    // is the one thing that stays wrong if it is ever wrong.
    late GalleryChromeController chrome;

    setUp(() => chrome = GalleryChromeController());
    tearDown(() => chrome.dispose());

    /// `arriveAt` is called from a build, so it defers its change to the next
    /// frame — which means there has to be one.
    Future<void> arriveAt(WidgetTester tester, Uri place) async {
      chrome.arriveAt(place);
      await tester.pump();
    }

    final list = pixivGalleryUri('/user/1700000000000');
    final work = pixivArtworkUri('456');
    final another = pixivArtworkUri('789');

    testWidgets('a folded header comes back on arriving at a list',
        (tester) async {
      // Nothing on a list scrolls it back on its own if the list is short, and
      // a viewer has no list at all — so arriving has to do it.
      await tester.pumpWidget(const SizedBox());
      await arriveAt(tester, work);
      chrome.visible.value = false;

      await arriveAt(tester, list);

      expect(chrome.visible.value, isTrue);
    });

    testWidgets('but reading on to the next work keeps it away',
        (tester) async {
      // A folder read full screen is one activity, not an arrival per picture.
      await tester.pumpWidget(const SizedBox());
      await arriveAt(tester, work);
      chrome.visible.value = false;

      await arriveAt(tester, another);

      expect(chrome.visible.value, isFalse);
    });

    testWidgets('the bars only come off over a work', (tester) async {
      await tester.pumpWidget(const SizedBox());
      await arriveAt(tester, list);

      // A grid folds its header for room; taking the status bar with it would
      // be a different thing entirely.
      chrome.visible.value = false;
      expect(chrome.immersive, isFalse);

      await arriveAt(tester, work);
      chrome.visible.value = false;
      expect(chrome.immersive, isTrue);
    });
  });

  testWidgets('the rows give their height back when they go', (tester) async {
    // Reclaiming the space is the whole point — a header that merely went
    // invisible would leave the grid exactly as short as before.
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Column(children: [
        GalleryChromeSlot(
          visible: visible,
          child: const SizedBox(height: 88, width: 200),
        ),
      ]),
    ));
    expect(tester.getSize(find.byType(GalleryChromeSlot)).height, 88);

    visible.value = false;
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(GalleryChromeSlot)).height, 0);

    visible.value = true;
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(GalleryChromeSlot)).height, 88);
  });
}
