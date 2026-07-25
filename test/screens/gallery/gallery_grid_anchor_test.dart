import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/screens/gallery/gallery_constants.dart';
import 'package:image_viewer/screens/gallery/scroll_anchor.dart';
import 'package:image_viewer/screens/gallery/widgets/gallery_grid.dart';

/// Pins the scroll anchor: that galleryRowStride agrees with what the grid
/// actually lays out (it mirrors the delegate's math by hand, so it has to be
/// checked against real geometry), and that the anchored item stays put when
/// the viewport width changes — the rotation jump this exists to fix.
void main() {
  const viewportHeight = 600.0;
  const narrow = 800.0;
  const wide = 1200.0;

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
  Future<void> pumpAt(WidgetTester tester, Widget widget) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(widget);
  }

  Widget harness(double width, {ScrollAnchor? anchor}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: viewportHeight,
              child: GalleryGrid(
                scrollController: controller,
                items: items,
                emptyMessage: 'empty',
                anchor: anchor,
                onAnchorChanged: (a) => reported = a,
                tileBuilder: (_, i) => Text(items[i].name),
              ),
            ),
          ),
        ),
      );

  /// Top edge of the grid's content area (viewport top + the grid's padding).
  double contentTop(WidgetTester tester) =>
      tester.getTopLeft(find.byType(GridView)).dy + galleryPadding;

  testWidgets('galleryRowStride matches the laid-out row positions',
      (tester) async {
    await pumpAt(tester, harness(narrow));

    final stride = galleryRowStride(narrow);
    // Scrolling by exactly three strides should bring row 3 flush to the top.
    controller.jumpTo(stride * 3);
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('item15')).dy, // row 3 = index 3 * 5
      closeTo(contentTop(tester), 0.01),
    );
  });

  testWidgets('the top-left item is reported as the anchor', (tester) async {
    await pumpAt(tester, harness(narrow));

    final stride = galleryRowStride(narrow);
    controller.jumpTo(stride * 3 + stride / 4);
    await tester.pump();

    expect(reported?.itemId, 'item15');
    expect(reported!.rowFraction, closeTo(0.25, 0.001));
  });

  testWidgets('widening the viewport keeps the same item at the top',
      (tester) async {
    await pumpAt(tester, harness(narrow));
    controller.jumpTo(galleryRowStride(narrow) * 3);
    await tester.pump();
    expect(reported?.itemId, 'item15');

    // Rotate: same grid, wider viewport, so rows are taller.
    await pumpAt(tester, harness(wide));
    await tester.pump(); // run the post-frame restore
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('item15')).dy,
      closeTo(contentTop(tester), 0.01),
    );
    // A pixel offset would have been kept as-is and landed elsewhere.
    expect(controller.offset, closeTo(galleryRowStride(wide) * 3, 0.01));
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

  testWidgets('an anchor naming an item that is gone leaves the view alone',
      (tester) async {
    await tester.pumpWidget(
        harness(narrow, anchor: const ScrollAnchor('filtered-out', 0)));
    await tester.pump();
    await tester.pump();

    expect(controller.offset, 0);
  });
}
