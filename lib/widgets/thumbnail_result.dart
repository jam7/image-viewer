import 'dart:typed_data';

/// Result of a thumbnail fetch attempt.
/// Used by gallery screens to track fetch state per item.
///
/// - null in the map → not yet attempted (show loading spinner)
/// - ThumbnailData → success (show image)
/// - ThumbnailFailed → failed (show icon based on reason)
sealed class ThumbnailResult {}

class ThumbnailData extends ThumbnailResult {
  final Uint8List data;
  ThumbnailData(this.data);
}

class ThumbnailFailed extends ThumbnailResult {
  final ThumbnailFailReason reason;
  ThumbnailFailed(this.reason);
}

enum ThumbnailFailReason {
  /// Nothing can be made of this item, and nothing will change that: a ZIP
  /// with no pictures in it, a PDF that would not render.
  notSupported,

  /// Nothing can be made of it *yet*, but the material may turn up — an
  /// unopened PDF (its pages need the whole file, which the viewer caches),
  /// or a favourite whose source is not connected this run.
  ///
  /// A provisional answer: the tile shows it, and asks again every time it is
  /// painted. Only failures whose re-check costs nothing may say this — see
  /// [ThumbnailNotReadyException].
  notYet,

  /// Network error or timeout
  timeout,
}
