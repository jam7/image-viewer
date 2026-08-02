import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Columns the grid shows across the narrow side of the device.
///
/// Five suits a tablet held upright. A phone wants fewer — the tile would be a
/// third of the width of one — so this is meant to become a setting; the value
/// is read through [GalleryLayout.of] alone so that change is one line here.
const galleryPortraitColumns = 5;

/// Smallest gap between tiles. A wider viewport gets a larger one, since the
/// remainder of fitting whole tiles goes into the gaps (ADR 012).
const gallerySpacing = 4.0;
const galleryPadding = 4.0;

/// Height of each of the two header rows — the tab strip and the toolbar
/// (ADR 009). One number so they cannot drift apart: two rows of different
/// heights read as two unrelated bars rather than one header.
///
/// Below the usual `kToolbarHeight` of 56 because there are two of them, over
/// a grid that shows barely three rows of thumbnails on a tablet in landscape.
const galleryHeaderRowHeight = 44.0;

/// Every number the grid is laid out from, worked out once (ADR 012).
///
/// The point of gathering them is that they are not independent. The tile
/// size decides what a thumbnail is stored at, the column count decides which
/// row an item is in, and a [ScrollAnchor] converts between rows and pixels at
/// two different moments — once when recording, once when restoring, possibly
/// at two different widths. Three call sites doing their own arithmetic from
/// the same constants is how those quietly stop agreeing.
///
/// The split that matters:
///
/// - [tile] comes from the screen's shortest side, so **it does not change
///   when the device is rotated**. That is what lets a device have exactly one
///   thumbnail size
/// - [columns] comes from the width being laid out, so it does change
class GalleryLayout {
  /// How many tiles fit across the width being laid out. At least one.
  final int columns;

  /// One tile's side, in logical pixels. Square, and the same in both
  /// orientations.
  final double tile;

  /// Gap between tiles: [gallerySpacing] plus whatever was left over from
  /// fitting whole tiles.
  final double spacing;

  /// Top of one row to the top of the next.
  final double rowStride;

  /// What a thumbnail for this device should be stored at, in device pixels.
  /// One number per device — [tile] does not turn with the screen.
  final int thumbnailPx;

  const GalleryLayout({
    required this.columns,
    required this.tile,
    required this.spacing,
    required this.rowStride,
    required this.thumbnailPx,
  });

  /// [width] is what is being laid out; [screen] and [devicePixelRatio] come
  /// from the window and decide the tile.
  factory GalleryLayout.of(
      double width, Size screen, double devicePixelRatio) {
    final tile = _baseTile(screen);
    final usable = width - galleryPadding * 2;
    // Whole tiles, each needing a gap before it except the first.
    final columns =
        math.max(1, ((usable + gallerySpacing) / (tile + gallerySpacing)).floor());
    final gaps = columns - 1;
    final spacing =
        gaps == 0 ? gallerySpacing : (usable - tile * columns) / gaps;
    return GalleryLayout(
      columns: columns,
      tile: tile,
      spacing: spacing,
      rowStride: tile + spacing,
      thumbnailPx: (tile * devicePixelRatio).round(),
    );
  }

  /// The tile as the device's upright width would give it. Uses
  /// [Size.shortestSide] rather than the current width so that rotating does
  /// not resize every tile — and so that the number a thumbnail is stored at
  /// is a property of the device, not of how it is being held.
  static double _baseTile(Size screen) {
    final across = screen.shortestSide -
        galleryPadding * 2 -
        gallerySpacing * (galleryPortraitColumns - 1);
    return across / galleryPortraitColumns;
  }

  /// By value, so a rebuild at the same width is not mistaken for a resize —
  /// what a resize triggers is a scroll restore.
  @override
  bool operator ==(Object other) =>
      other is GalleryLayout &&
      other.columns == columns &&
      other.tile == tile &&
      other.spacing == spacing;

  @override
  int get hashCode => Object.hash(columns, tile, spacing);

  SliverGridDelegate get gridDelegate =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
      );

  /// Index of the first item in [row], clamped to a list of [length].
  int firstOfRow(int row, int length) =>
      (row * columns).clamp(0, length).toInt();
}
