import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/services/sources/smb_source.dart';

/// A PDF page is drawing instructions, so somebody has to choose how many
/// pixels to make (ADR 012). That choice used to be the constant 2.0, which is
/// an A4-shaped guess: page dimensions are points, and points are pixels at
/// 72 dpi, so a scan placed at 72 dpi has a page box the size of the scan and
/// nothing about x2 fits it.
void main() {
  // The device ADR 012 was measured on, in device pixels.
  const screen = Size(800, 1340);

  double pixelsFor(double w, double h, Size? display) =>
      w * SmbSource.displayScale(w, h, display) *
      h * SmbSource.displayScale(w, h, display);

  test('a page is made big enough to fill the screen it is read on', () {
    // The book that prompted the measuring: 1078x1511pt.
    final scale = SmbSource.displayScale(1078, 1511, screen);

    expect(1078 * scale, closeTo(800, 1), reason: 'as wide as the screen');
    expect(1511 * scale, lessThan(1340), reason: 'and no taller than it');
  });

  test('and no bigger, which is where the old constant went wrong', () {
    final now = SmbSource.displayScale(1078, 1511, screen);

    expect(pixelsFor(1078, 1511, screen), lessThan(pixelsFor(1078, 1511, null)));
    expect(now, lessThan(2.0));
  });

  test('how wrong the old constant was depended on the page box', () {
    // x2 was tuned for A4 on a taller screen than this one, so on this device
    // it overshoots everything -- but by 1.5 times for an A4 page and 2.7 for
    // the scanned book, whose box is 1.8 times A4. That is the part a constant
    // could never get right: the page box is not a paper size.
    final a4 = SmbSource.displayScale(595, 842, screen);
    final scan = SmbSource.displayScale(1078, 1511, screen);

    expect(2.0 / a4, closeTo(1.5, 0.1));
    expect(2.0 / scan, closeTo(2.7, 0.1));
  });

  test('the screen may be turned after the page is cached', () {
    // Whichever way round the screen is given, the answer is the same: the
    // page is stored once and read in both orientations.
    expect(
      SmbSource.displayScale(1078, 1511, const Size(800, 1340)),
      SmbSource.displayScale(1078, 1511, const Size(1340, 800)),
    );
  });

  test('a caller that does not know the screen keeps the old behaviour', () {
    expect(SmbSource.displayScale(1078, 1511, null), 2.0);
  });
}
