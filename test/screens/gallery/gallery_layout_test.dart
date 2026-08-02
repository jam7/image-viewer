import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/screens/gallery/gallery_constants.dart';

/// How wide a tile is, and how many fit, decides three separate things: what
/// the grid looks like, which row a [ScrollAnchor] resolves to, and how many
/// pixels a thumbnail is stored at (ADR 012). They have to agree, so the
/// arithmetic is pinned here rather than left to three call sites.
void main() {
  setUp(GalleryLayout.forgetTileSize);

  // The device the numbers in ADR 012 were measured on: 800x1340 physical at
  // density 180, so 711x1191 logical.
  const tablet = Size(711, 1191);

  group('the base tile', () {
    test('is the portrait five-column tile, whichever way round it is', () {
      final portrait = GalleryLayout.of(tablet.width, tablet, 1.125);
      final landscape = GalleryLayout.of(tablet.height, tablet, 1.125);

      expect(portrait.tile, closeTo(landscape.tile, 0.001),
          reason: 'a rotation must not change what a thumbnail is stored at');
      expect(portrait.columns, galleryPortraitColumns);
    });

    test('is settled by the first window and not moved by a resize', () {
      // A desktop window can be dragged to any size. Recomputing would change
      // what thumbnails are stored at every time it moved, and L2 would fill
      // with the same pictures at a handful of sizes (ADR 012 決定 1).
      final opened = GalleryLayout.of(1200, const Size(1200, 800), 1.0);

      final maximised = GalleryLayout.of(2560, const Size(2560, 1440), 1.0);

      expect(maximised.tile, opened.tile);
      expect(maximised.thumbnailPx, opened.thumbnailPx);
      expect(maximised.columns, greaterThan(opened.columns),
          reason: 'the extra width goes into columns');
    });

    test('is five columns of the narrow side, even opened landscape', () {
      // Which is how a desktop window usually opens. Dividing the width would
      // give tiles half again too big.
      final landscape = GalleryLayout.of(1200, const Size(1200, 800), 1.0);

      expect(landscape.tile, closeTo((800 - 24) / 5, 0.001));
    });

    test('adapts to the device rather than being a fixed number of dp', () {
      // A fixed tile would leave a phone with two columns. Two devices in one
      // test means forgetting in between, which is the rule showing through:
      // one run has one tile, and only a test ever sees a second device.
      final phone = GalleryLayout.of(360, const Size(360, 780), 3.0);
      GalleryLayout.forgetTileSize();
      final tab = GalleryLayout.of(tablet.width, tablet, 1.125);

      expect(phone.columns, galleryPortraitColumns);
      expect(phone.tile, lessThan(tab.tile));
    });
  });

  group('a wider viewport', () {
    test('gets more columns, not bigger tiles', () {
      final portrait = GalleryLayout.of(tablet.width, tablet, 1.125);
      final landscape = GalleryLayout.of(tablet.height, tablet, 1.125);

      expect(landscape.columns, greaterThan(portrait.columns));
      expect(landscape.tile, closeTo(portrait.tile, 0.001));
    });

    test('spends the remainder on the gaps', () {
      final landscape = GalleryLayout.of(tablet.height, tablet, 1.125);

      // What is laid out has to add up to what there is.
      final used = landscape.tile * landscape.columns +
          landscape.spacing * (landscape.columns - 1) +
          galleryPadding * 2;
      expect(used, closeTo(tablet.height, 0.001));
      expect(landscape.spacing, greaterThanOrEqualTo(gallerySpacing));
    });

    test('never goes below one column, however narrow', () {
      final sliver = GalleryLayout.of(40, tablet, 1.125);

      expect(sliver.columns, 1);
      expect(sliver.spacing, greaterThanOrEqualTo(gallerySpacing));
    });
  });

  group('the thumbnail size', () {
    test('is the tile in device pixels, so one number per device', () {
      final portrait = GalleryLayout.of(tablet.width, tablet, 1.125);
      final landscape = GalleryLayout.of(tablet.height, tablet, 1.125);

      expect(portrait.thumbnailPx, landscape.thumbnailPx);
      expect(portrait.thumbnailPx, (portrait.tile * 1.125).round());
    });

    test('follows the pixel ratio, not the logical size', () {
      final coarse = GalleryLayout.of(tablet.width, tablet, 1.0);
      final fine = GalleryLayout.of(tablet.width, tablet, 3.0);
      // Same tile in dp either way; the pixels differ because the screen does.

      expect(fine.thumbnailPx, greaterThan(coarse.thumbnailPx));
    });
  });

  group('the row stride', () {
    test('is a tile plus the gap below it', () {
      final layout = GalleryLayout.of(tablet.width, tablet, 1.125);

      expect(layout.rowStride, closeTo(layout.tile + layout.spacing, 0.001));
    });

    test('places the last row of a full grid inside the content', () {
      // What _applyAnchor multiplies by. A stride that disagreed with the
      // delegate would put a restore a few rows off, and further off the
      // further down the list it was.
      final layout = GalleryLayout.of(tablet.width, tablet, 1.125);
      const rows = 10;

      final content = layout.rowStride * rows - layout.spacing;
      expect(content, greaterThan(layout.tile * rows));
    });
  });
}
