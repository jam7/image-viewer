import 'package:flutter/widgets.dart';

const galleryCrossAxisCount = 5;
const gallerySpacing = 4.0;
const galleryPadding = 4.0;

/// Height of each of the two header rows — the tab strip and the toolbar
/// (ADR 009). One number so they cannot drift apart: two rows of different
/// heights read as two unrelated bars rather than one header.
///
/// Below the usual `kToolbarHeight` of 56 because there are two of them, over
/// a grid that shows barely three rows of thumbnails on a tablet in landscape.
const galleryHeaderRowHeight = 44.0;

const galleryGridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: galleryCrossAxisCount,
  crossAxisSpacing: gallerySpacing,
  mainAxisSpacing: gallerySpacing,
);

/// Distance from one row's top to the next when the grid is laid out at
/// [viewportWidth]: tile height plus the gap below it.
///
/// Mirrors what [galleryGridDelegate] does with the same numbers — tiles are
/// square because `childAspectRatio` defaults to 1 — and lives next to the
/// delegate so the two cannot drift apart. Used to convert between a pixel
/// offset and a row, which is how a [ScrollAnchor] survives a resize.
double galleryRowStride(double viewportWidth) {
  final crossAxisExtent = viewportWidth - galleryPadding * 2;
  final tileWidth =
      (crossAxisExtent - gallerySpacing * (galleryCrossAxisCount - 1)) /
          galleryCrossAxisCount;
  return tileWidth + gallerySpacing;
}
