import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/services/video/video_thumbnail_service.dart';

/// The frame buffer arrives as bytes alone — media_kit discards the
/// dimensions mpv sends with it — so the size is derived and has to be
/// derived right: the first version used the storage size for everything,
/// and every video with a pixel aspect ratio came out as striped noise.
void main() {
  test('an anamorphic frame is its display size, not its storage size', () {
    // A DVD-style 720x480 displayed at 720x540: the buffer mpv hands over
    // is the display-sized one.
    final size =
        frameSizeOf(720 * 540 * 4, w: 720, h: 480, dw: 720, dh: 540);

    expect(size, (720, 540));
  });

  test('a square-pixel frame matches either way and stays itself', () {
    final size =
        frameSizeOf(640 * 480 * 4, w: 640, h: 480, dw: 640, dh: 480);

    expect(size, (640, 480));
  });

  test('a storage-sized buffer is accepted when the display size differs',
      () {
    // Belt and braces: if some demuxer reports a PAR that the screenshot
    // machinery did not apply, the bytes still say which answer is true.
    final size =
        frameSizeOf(720 * 480 * 4, w: 720, h: 480, dw: 720, dh: 540);

    expect(size, (720, 480));
  });

  test('a buffer that matches neither size is refused, not guessed', () {
    // A padded length divides evenly by more than one height, so a guess
    // would be silent and sometimes wrong — the very bug this fixes.
    final size =
        frameSizeOf(720 * 480 * 4 + 64, w: 720, h: 480, dw: 720, dh: 540);

    expect(size, isNull);
  });

  test('missing display dimensions fall back to storage', () {
    final size = frameSizeOf(320 * 240 * 4, w: 320, h: 240, dw: null, dh: null);

    expect(size, (320, 240));
  });

  /// [count] pixels of one BGRA colour followed by [count] of another.
  Uint8List half(List<int> first, List<int> second, int count) {
    final out = Uint8List(count * 8);
    for (var i = 0; i < count; i++) {
      out.setRange(i * 4, i * 4 + 4, first);
      out.setRange((count + i) * 4, (count + i) * 4 + 4, second);
    }
    return out;
  }

  test('a watermark plate is dark: grey ground, bright mark', () {
    // The case the near-black test missed: the ground is around 50 per
    // channel -- nowhere near black, plainly dark -- with a bright mark on
    // top. Luminance counts the ground, so the plate measures mostly dark.
    final plate =
        half(const [50, 50, 50, 255], const [235, 235, 235, 255], 4096);

    expect(darkFractionOf(plate), closeTo(0.5, 0.01));
  });

  test('a black title card measures dark, a lit scene does not', () {
    final card = half(const [0, 0, 0, 255], const [12, 8, 4, 255], 4096);
    final scene =
        half(const [90, 120, 180, 255], const [130, 160, 110, 255], 4096);

    expect(darkFractionOf(card), 1.0);
    expect(darkFractionOf(scene), 0.0);
  });

  test('half dark is half dark', () {
    final frame = half(const [0, 0, 0, 255], const [200, 200, 200, 255], 4096);

    expect(darkFractionOf(frame), closeTo(0.5, 0.01));
  });

  test('darkness follows the eye, not the channel values', () {
    // Deep blue reads dark to a person even at a high channel value, and
    // green reads bright: Rec.601 weights say so too. BGRA order.
    final blue = half(const [220, 0, 0, 255], const [220, 0, 0, 255], 4096);
    final green = half(const [0, 160, 0, 255], const [0, 160, 0, 255], 4096);

    expect(darkFractionOf(blue), 1.0);
    expect(darkFractionOf(green), 0.0);
  });
}
