import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/screens/gallery/gallery_constants.dart';
import 'package:image_viewer/screens/gallery/widgets/thumbnail_image.dart';

/// A tile decodes at the size it is drawn, not at the size the bytes happen to
/// be (ADR 012). The saving is in Flutter's own image cache, which is measured
/// in decoded bytes, so nothing about the stored file shows it — only what is
/// asked of the decoder.
void main() {
  setUp(GalleryLayout.forgetTileSize);

  ResizeImage resizerIn(WidgetTester tester) =>
      tester.widget<Image>(find.byType(Image)).image as ResizeImage;

  Future<void> pumpOn(WidgetTester tester, Size screen, double dpr) async {
    tester.view.physicalSize = Size(screen.width * dpr, screen.height * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ThumbnailImage(Uint8List.fromList(const [1, 2, 3]))),
    ));
  }

  testWidgets('asks the decoder for the tile size in device pixels',
      (tester) async {
    await pumpOn(tester, const Size(711, 1191), 1.125);

    final expected =
        GalleryLayout.of(711, const Size(711, 1191), 1.125).thumbnailPx;
    expect(resizerIn(tester).width, expected);
    expect(resizerIn(tester).height, isNull,
        reason: 'a height as well would stretch it to both');
  });

  testWidgets('asks for the same size whichever way the device is held',
      (tester) async {
    await pumpOn(tester, const Size(711, 1191), 1.125);
    final upright = resizerIn(tester).width;

    await pumpOn(tester, const Size(1191, 711), 1.125);

    expect(resizerIn(tester).width, upright);
  });

  testWidgets('asks for more on a denser screen', (tester) async {
    await pumpOn(tester, const Size(711, 1191), 1.0);
    final coarse = resizerIn(tester).width!;

    await pumpOn(tester, const Size(711, 1191), 3.0);

    expect(resizerIn(tester).width, greaterThan(coarse));
  });
}
