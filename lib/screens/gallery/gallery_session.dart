import '../../models/image_source.dart';
import '../../services/sources/image_source_provider.dart';
import '../../services/thumbnail/thumbnail_loader.dart';

/// One browsing session (ADR 007): a lazy-paged item list plus its thumbnail
/// loader and scroll position. Owns the session state that used to be scattered
/// across the source (pagination cursor) and the screen (loaded items, scroll).
///
/// A session is one *place* being browsed. A tab (ADR 008) is a stack of these
/// — its history — and the tab, not the session, carries the identity; hence
/// [sourceUri] describes where this session looks rather than naming a tab.
///
/// The source ([provider]) is stateless: [GallerySession] drives it via
/// `loadPage(cursor)` and holds the resulting [loaded] list and [_cursor].
/// Directories and other non-thumbnail items are kept in [loaded] (for the
/// grid) but excluded from the loader via [_thumbnailFilter].
class GallerySession {
  /// Where this session looks (also cache-key prefix / restore key). Not a tab
  /// identity — the same URI may be open in several tabs (ADR 008).
  final Uri sourceUri;
  final ImageSourceProvider provider;

  /// Path passed to `loadPage` (e.g. an SMB directory). Null for sources whose
  /// list is fully described by [sourceUri].
  final String? path;

  /// Thumbnail engine for this session. Its `source` is [provider].
  final ThumbnailLoader thumbnails;

  final List<ImageSource> loaded = [];
  double scrollOffset = 0;

  /// Items fed to [thumbnails] = [loaded] minus filtered-out items (e.g.
  /// directories). Same order the loader batches over, so callers can map an
  /// item to its loader index (for the batch trigger) or build a viewer list.
  final List<ImageSource> _thumbnailItems = [];
  List<ImageSource> get thumbnailItems => _thumbnailItems;

  final bool Function(ImageSource) _thumbnailFilter;
  /// A finite, already-known list (e.g. favorites) served as the single page
  /// instead of calling [provider.loadPage]. Thumbnails still come from
  /// [thumbnails] (ADR 007; interim until a fav:// paged source in Phase 3).
  final List<ImageSource>? _seedItems;
  Object? _cursor;
  bool _firstPageLoaded = false;
  bool _loadingPage = false;

  GallerySession({
    required this.sourceUri,
    required this.provider,
    required this.thumbnails,
    this.path,
    bool Function(ImageSource)? thumbnailFilter,
    List<ImageSource>? seedItems,
  })  : _thumbnailFilter = thumbnailFilter ?? ((_) => true),
        _seedItems = seedItems;

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
      final page = _seedItems != null
          ? PageResult(items: firstPage ? _seedItems : const [])
          : await provider.loadPage(path: path, cursor: _cursor);
      _cursor = page.nextCursor;
      _firstPageLoaded = true;
      loaded.addAll(page.items);

      final eligible = page.items.where(_thumbnailFilter).toList();
      if (firstPage) {
        thumbnails.setItems(eligible);
      } else {
        thumbnails.addItems(eligible);
      }
      _thumbnailItems.addAll(eligible);
      return page.items;
    } finally {
      _loadingPage = false;
    }
  }

  Future<void> dispose() => thumbnails.dispose();
}
