import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
