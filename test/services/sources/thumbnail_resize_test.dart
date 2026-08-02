import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/services/sources/thumbnail_resize.dart';

/// Exercises the real decoder, which is the whole point: the first version of
/// this released the ImageDescriptor as soon as the codec was made, and the
/// decode thread then segfaulted on a null pointer. Nothing in a test that
/// hands it invented bytes can see that — the picture has to actually be
/// decoded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A real encoded PNG of the given size.
  Future<Uint8List> pngOf(int width, int height) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF3366AA),
    );
    final image = await recorder.endRecording().toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  Future<ui.Image> decode(Uint8List data) async {
    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  testWidgets('a picture larger than the tile comes back at the tile size',
      (tester) async {
    await tester.runAsync(() async {
      final big = await pngOf(400, 300);

      final small = await shrinkToFit(big, 100);

      final image = await decode(small);
      expect(image.width, 100);
      expect(image.height, 75, reason: 'and the shape is kept');
      image.dispose();
    });
  });

  testWidgets('one already small enough is handed straight back',
      (tester) async {
    await tester.runAsync(() async {
      final small = await pngOf(80, 60);

      // The same bytes, not a re-encode: nothing is gained by rewriting a
      // picture that is already the size it will be drawn.
      expect(identical(await shrinkToFit(small, 100), small), isTrue);
    });
  });

  testWidgets('the long edge is what is measured, whichever it is',
      (tester) async {
    await tester.runAsync(() async {
      final wide = await decode(await shrinkToFit(await pngOf(400, 100), 200));
      final tall = await decode(await shrinkToFit(await pngOf(100, 400), 200));

      expect(wide.width, 200);
      expect(tall.height, 200);
      wide.dispose();
      tall.dispose();
    });
  });

  testWidgets('bytes that are not a picture are left alone', (tester) async {
    await tester.runAsync(() async {
      final rubbish = Uint8List.fromList(const [1, 2, 3, 4]);

      expect(identical(await shrinkToFit(rubbish, 100), rubbish), isTrue);
    });
  });

  /// Raw BGRA, [rowPadding] extra bytes on every row — mpv pads its rows
  /// sometimes, and the reader has to survive that.
  Uint8List bgraOf(int width, int height,
      {int rowPadding = 0, required List<int> bgra}) {
    final rowBytes = width * 4 + rowPadding;
    final out = Uint8List(rowBytes * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        out.setRange(y * rowBytes + x * 4, y * rowBytes + x * 4 + 4, bgra);
      }
    }
    return out;
  }

  testWidgets('a raw frame larger than the tile comes back at the tile size',
      (tester) async {
    await tester.runAsync(() async {
      final frame = bgraOf(400, 300, bgra: const [0xAA, 0x66, 0x33, 0xFF]);

      final png = await shrinkRawFrame(frame, 400, 300, 200);

      final image = await decode(png!);
      expect(image.width, 200);
      expect(image.height, 150);
      image.dispose();
    });
  });

  testWidgets('padded rows do not shear the raw frame', (tester) async {
    await tester.runAsync(() async {
      // Two pixels of padding per row, zeroes, as mpv's aligned strides give.
      // A reader that assumed width * 4 would start each row 8 bytes early
      // and read that zero padding into the picture. The pixels are one
      // colour, so a clean read comes back as that colour everywhere.
      // (Skia rejects a rowBytes that is not a whole number of pixels, so
      // padding is always a multiple of 4 in practice.)
      final frame =
          bgraOf(50, 40, rowPadding: 8, bgra: const [0x22, 0x44, 0x88, 0xFF]);

      final png = await shrinkRawFrame(frame, 50, 40, 200);

      final image = await decode(png!);
      expect(image.width, 50, reason: 'already smaller than the tile');
      final pixels =
          (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!
              .buffer
              .asUint8List();
      expect(pixels.sublist(0, 4), const [0x88, 0x44, 0x22, 0xFF],
          reason: 'BGRA in, RGBA out, same colour');
      final last = pixels.length - 4;
      expect(pixels.sublist(last), const [0x88, 0x44, 0x22, 0xFF],
          reason: 'the last pixel too, so no row drifted');
      image.dispose();
    });
  });
}
