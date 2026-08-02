import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/screens/gallery/gallery_constants.dart';
import 'package:image_viewer/screens/gallery/scroll_anchor.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_grid.dart';

/// Pins the scroll anchor: that [GalleryLayout] agrees with what the grid
/// actually lays out (it mirrors the delegate's math by hand, so it has to be
/// checked against real geometry), and that the anchored item stays put when
/// the viewport width changes — the rotation jump this exists to fix.
///
/// Since ADR 012 a wider viewport means *more columns* rather than wider
/// tiles, so the same item is in a different row on either side of a rotation.
/// That is what the anchor naming an item rather than a row is for.
void main() {
  const viewportHeight = 600.0;
  const narrow = 800.0;
  const wide = 1200.0;

  /// The surface below is 1400x800, which is what the grid sees as the screen.
  GalleryLayout layoutAt(double width) =>
      GalleryLayout.of(width, const Size(1400, 800), 1.0);

  final items = [
    for (var i = 0; i < 100; i++)
      ImageSource(
        id: 'item$i',
        name: 'item$i',
        uri: 'test://item$i',
        type: ImageSourceType.smb,
      ),
  ];

  late ScrollController controller;
  ScrollAnchor? reported;

  setUp(() {
    controller = ScrollController();
    reported = null;
  });

  tearDown(() => controller.dispose());

  /// The default 800x600 test surface would clamp the "wide" case back to 800
  /// and quietly test nothing, so give both widths room.
  ///
  /// Set on the view rather than with `setSurfaceSize`, which moves the render
  /// surface without moving what MediaQuery reports — and MediaQuery is where
  /// the tile size comes from since ADR 012.
  Future<void> pumpAt(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
  }

  Widget harness(
    double width, {
    ScrollAnchor? anchor,
    List<ImageSource>? shown,
    Object? restoreKey,
  }) {
    final list = shown ?? items;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: viewportHeight,
            child: GalleryGrid(
              scrollController: controller,
              items: list,
              emptyMessage: 'empty',
              anchor: anchor,
              restoreKey: restoreKey,
              onAnchorChanged: (a) => reported = a,
              tileBuilder: (_, i) => Text(list[i].name),
            ),
          ),
        ),
      ),
    );
  }

  /// Top edge of the grid's content area (viewport top + the grid's padding).
  double contentTop(WidgetTester tester) =>
      tester.getTopLeft(find.byType(GridView)).dy + galleryPadding;

  testWidgets('the row stride matches the laid-out row positions',
      (tester) async {
    await pumpAt(tester, harness(narrow));

    final layout = layoutAt(narrow);
    expect(layout.columns, 5, reason: 'the narrow case is the upright one');
    // Scrolling by exactly three strides should bring row 3 flush to the top.
    controller.jumpTo(layout.rowStride * 3);
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('item15')).dy, // row 3 = index 3 * 5
      closeTo(contentTop(tester), 0.01),
    );
  });

  testWidgets('a wider viewport lays out more columns of the same size',
      (tester) async {
    await pumpAt(tester, harness(wide));

    final layout = layoutAt(wide);
    expect(layout.columns, greaterThan(5));
    // The first tile of the second row, wherever that now falls.
    expect(
      tester.getTopLeft(find.text('item${layout.columns}')).dy,
      closeTo(contentTop(tester) + layout.rowStride, 0.01),
    );
  });

  testWidgets('the top-left item is reported as the anchor', (tester) async {
    await pumpAt(tester, harness(narrow));

    final stride = layoutAt(narrow).rowStride;
    controller.jumpTo(stride * 3 + stride / 4);
    await tester.pump();

    expect(reported?.itemId, 'item15');
    expect(reported!.rowFraction, closeTo(0.25, 0.001));
  });

  testWidgets('widening the viewport keeps the same item at the top',
      (tester) async {
    await pumpAt(tester, harness(narrow));
    controller.jumpTo(layoutAt(narrow).rowStride * 3);
    await tester.pump();
    expect(reported?.itemId, 'item15');

    // Rotate: same grid, wider viewport, so more columns and a taller row.
    await pumpAt(tester, harness(wide));
    await tester.pump(); // run the post-frame restore
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('item15')).dy,
      closeTo(contentTop(tester), 0.01),
    );
    // Row 3 of five columns is not row 3 of seven. A pixel offset, or a row
    // number, would have landed somewhere else entirely.
    final wideLayout = layoutAt(wide);
    expect(controller.offset,
        closeTo(wideLayout.rowStride * (15 ~/ wideLayout.columns), 0.01));
  });

  testWidgets('an incoming anchor is restored on first layout',
      (tester) async {
    await pumpAt(tester, harness(narrow, anchor: const ScrollAnchor('item40', 0)));
    await tester.pump(); // run the post-frame restore
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('item40')).dy, // row 8
      closeTo(contentTop(tester), 0.01),
    );
  });

  testWidgets('a place being re-read is restored once its items arrive',
      (tester) async {
    // Re-reading a list (the favorites list does this on every return from the
    // viewer) installs a fresh, empty session and loads its first page
    // asynchronously. The restore is asked for while there is still nothing to
    // aim at, so it has to wait for the items rather than give up.
    await pumpAt(tester, harness(narrow, restoreKey: 'first'));
    controller.jumpTo(layoutAt(narrow).rowStride * 3);
    await tester.pump();
    expect(reported?.itemId, 'item15');

    // The same list instance, filled in place — which is what a session hands
    // out. Anything comparing the old and new widget's items is comparing one
    // object with itself.
    final growing = <ImageSource>[];
    await pumpAt(tester,
        harness(narrow, anchor: reported, shown: growing, restoreKey: 'reread'));
    await tester.pump();
    await tester.pump();

    growing.addAll(items);
    await pumpAt(tester,
        harness(narrow, anchor: reported, shown: growing, restoreKey: 'reread'));
    await tester.pump();
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('item15')).dy,
      closeTo(contentTop(tester), 0.01),
    );
  });

  testWidgets('an anchor naming an item that is gone leaves the view alone',
      (tester) async {
    await tester.pumpWidget(
        harness(narrow, anchor: const ScrollAnchor('filtered-out', 0)));
    await tester.pump();
    await tester.pump();

    expect(controller.offset, 0);
  });
}
