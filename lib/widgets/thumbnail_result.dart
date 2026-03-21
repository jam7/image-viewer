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
  /// Thumbnail fetch is not supported for this file type (e.g. ZIP)
  notSupported,

  /// Network error or timeout
  timeout,
}

/// Thrown by source providers when thumbnail is not available for this type.
class ThumbnailNotSupportedException implements Exception {
  final String message;
  ThumbnailNotSupportedException(this.message);
  @override
  String toString() => 'ThumbnailNotSupportedException: $message';
}
