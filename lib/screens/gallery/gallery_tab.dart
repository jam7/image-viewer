import '../../models/image_source.dart';
import '../../services/sources/image_source_provider.dart';
import '../../services/thumbnail/thumbnail_loader.dart';

/// One browsing session (ADR 007): a lazy-paged item list plus its thumbnail
/// loader and scroll position. Owns the session state that used to be scattered
/// across the source (pagination cursor) and the screen (loaded items, scroll).
///
/// The source ([provider]) is stateless: [GalleryTab] drives it via
/// `loadPage(cursor)` and holds the resulting [loaded] list and [_cursor].
/// Directories and other non-thumbnail items are kept in [loaded] (for the
/// grid) but excluded from the loader via [_thumbnailFilter].
class GalleryTab {
  /// Stable identity for this tab (also cache-key prefix / restore key).
  final Uri sourceUri;
  final ImageSourceProvider provider;

  /// Path passed to `loadPage` (e.g. an SMB directory). Null for sources whose
  /// list is fully described by [sourceUri].
  final String? path;

  /// Thumbnail engine for this tab. Its `source` is [provider].
  final ThumbnailLoader thumbnails;

  final List<ImageSource> loaded = [];
  double scrollOffset = 0;

  final bool Function(ImageSource) _thumbnailFilter;
  Object? _cursor;
  bool _firstPageLoaded = false;
  bool _loadingPage = false;

  GalleryTab({
    required this.sourceUri,
    required this.provider,
    required this.thumbnails,
    this.path,
    bool Function(ImageSource)? thumbnailFilter,
  }) : _thumbnailFilter = thumbnailFilter ?? ((_) => true);

  /// True until the first page is loaded, then true while more pages remain.
  bool get hasMore => !_firstPageLoaded || _cursor != null;
  bool get isLoadingPage => _loadingPage;

  /// Load the next page (the first page if none yet), append it to [loaded] and
  /// feed the thumbnail-eligible items to [thumbnails]. Returns the new items
  /// (empty if a load is already running or the list is exhausted).
  Future<List<ImageSource>> loadNextPage() async {
    if (_loadingPage || (_firstPageLoaded && _cursor == null)) {
      return const [];
    }
    _loadingPage = true;
    try {
      final firstPage = !_firstPageLoaded;
      final page = await provider.loadPage(path: path, cursor: _cursor);
      _cursor = page.nextCursor;
      _firstPageLoaded = true;
      loaded.addAll(page.items);

      final eligible = page.items.where(_thumbnailFilter).toList();
      if (firstPage) {
        thumbnails.setItems(eligible);
      } else {
        thumbnails.addItems(eligible);
      }
      return page.items;
    } finally {
      _loadingPage = false;
    }
  }

  Future<void> dispose() => thumbnails.dispose();
}
