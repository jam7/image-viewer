/// How far into one work the reader has got: which page, and how far into a
/// video. The viewer's counterpart to `ScrollAnchor`, which says the same
/// thing about a grid.
///
/// Kept by the place it belongs to (`GallerySession`) rather than by the
/// screen showing it, because the screen is thrown away whenever its tab stops
/// being the active one — and coming back to a tab used to mean starting the
/// work again from its first page, and a video from silence at zero.
///
/// [itemId] is here for the same reason it is on a scroll anchor: a mark is
/// about one particular work, and the place it is written to may have moved on
/// by the time it arrives. A mark whose id does not match is not applied.
///
/// It is not in the address (ADR 008 would make it a separate history entry
/// otherwise, one per page turned). A `?p=` / `?t=` form of the same thing is
/// a later question; this is shaped so that answering it means moving these
/// two fields, not inventing them.
class ViewerMark {
  /// The work this is about — [id] of the item, as the source spells it.
  final String itemId;

  /// Which page of it, for a work that has several (a ZIP, a PDF, a Pixiv
  /// work of many pictures). Zero for everything else.
  final int page;

  /// How far into the video, and how long the whole of it is.
  ///
  /// [total] is remembered as well so that the bar can be drawn at the right
  /// place *before* anything is opened. Working it out would mean connecting
  /// to the share and decoding, every time a tab is glanced at.
  final Duration at;
  final Duration total;

  /// Whether the video should stay stopped on arrival.
  ///
  /// Separate from [at] rather than implied by it. A position on its own means
  /// "start here", which is what a pasted `?t=` will want; this means "and do
  /// not start". Leaving a tab writes it, because a tab may be come back to
  /// hours later and sound starting by itself is never what was meant. Moving
  /// along the list with a swipe is the other case, and does not come through
  /// here at all — one is a continuous act, the other is not.
  final bool paused;

  const ViewerMark(
    this.itemId, {
    this.page = 0,
    this.at = Duration.zero,
    this.total = Duration.zero,
    this.paused = false,
  });

  /// This mark, if it is about [itemId] — null when the reader has moved on.
  ViewerMark? forItem(String id) => itemId == id ? this : null;

  @override
  bool operator ==(Object other) =>
      other is ViewerMark &&
      other.itemId == itemId &&
      other.page == page &&
      other.at == at &&
      other.total == total &&
      other.paused == paused;

  @override
  int get hashCode => Object.hash(itemId, page, at, total, paused);

  @override
  String toString() =>
      'ViewerMark($itemId, page $page, ${at.inSeconds}/${total.inSeconds}s'
      '${paused ? ', paused' : ''})';
}
