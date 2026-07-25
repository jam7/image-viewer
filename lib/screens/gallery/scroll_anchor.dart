/// Where a gallery grid is scrolled to, expressed as the item resting at the
/// top-left rather than as a pixel offset.
///
/// A pixel offset does not survive a change of viewport width: the grid is a
/// fixed number of square tiles, so row height scales with width and the same
/// offset lands on a different row after a rotation. An item anchor is
/// independent of layout — restoring divides by whatever the column count and
/// row height are at that moment.
///
/// The anchor names the item by [itemId] rather than by its position in the
/// list, because the visible list is not the loaded list: the Pixiv screen
/// applies a display-only page-count filter, so ordinal N can mean a different
/// work after the filter changes.
class ScrollAnchor {
  /// Item at the top-left of the viewport.
  final String itemId;

  /// How far past that item's row the view is scrolled, as a fraction of the
  /// row height. Keeps a restore from snapping to the row boundary.
  final double rowFraction;

  const ScrollAnchor(this.itemId, this.rowFraction);

  @override
  bool operator ==(Object other) =>
      other is ScrollAnchor &&
      other.itemId == itemId &&
      other.rowFraction == rowFraction;

  @override
  int get hashCode => Object.hash(itemId, rowFraction);

  @override
  String toString() => 'ScrollAnchor($itemId, +${rowFraction.toStringAsFixed(2)} row)';
}
