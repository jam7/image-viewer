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
}
