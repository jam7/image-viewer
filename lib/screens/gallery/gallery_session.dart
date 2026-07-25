import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/sources/image_source_provider.dart';
import '../../services/thumbnail/thumbnail_loader.dart';
import '../../widgets/thumbnail_result.dart';
import 'gallery_constants.dart';

/// One browsing session (ADR 007): a lazy-paged item list plus its thumbnail
/// loader, thumbnail results and scroll position. Owns the session state that
/// used to be scattered across the source (pagination cursor) and the screen
/// (loaded items, thumbnail results, scroll).
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

  /// Called when a thumbnail result arrives and the view should repaint. Page
  /// loads are awaited by the caller instead, so they do not go through here.
  final void Function()? onChanged;

  /// Thumbnail engine for this session. Its `source` is [provider] and its
  /// results land in this session (see [thumbnailFor]).
  late final ThumbnailLoader thumbnails;

  final List<ImageSource> loaded = [];
  double scrollOffset = 0;

  /// Items fed to [thumbnails] = [loaded] minus filtered-out items (e.g.
  /// directories). Same order the loader batches over, so callers can map an
  /// item to its loader index (for the batch trigger) or build a viewer list.
  final List<ImageSource> _thumbnailItems = [];
  List<ImageSource> get thumbnailItems => _thumbnailItems;

  /// Decoded thumbnails, by item id. Lives here rather than in the screen so a
  /// session keeps its thumbnails while another one is on screen (ADR 008).
  final Map<String, ThumbnailResult> _thumbnailResults = {};

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
    required CacheManager cacheManager,
    this.path,
    this.onChanged,
    bool Function(ImageSource)? thumbnailFilter,
    List<ImageSource>? seedItems,
  })  : _thumbnailFilter = thumbnailFilter ?? ((_) => true),
        _seedItems = seedItems {
    thumbnails = ThumbnailLoader(
      source: provider,
      cacheManager: cacheManager,
      batchSize: galleryCrossAxisCount * 6,
      parallelCount: galleryCrossAxisCount,
      onResult: _recordThumbnail,
    );
  }

  /// True until the first page is loaded, then true while more pages remain.
  bool get hasMore => !_firstPageLoaded || _cursor != null;
  bool get isLoadingPage => _loadingPage;

  /// The thumbnail for [id], or null if it has not been fetched yet.
  ThumbnailResult? thumbnailFor(String id) => _thumbnailResults[id];

  bool get hasThumbnailResults => _thumbnailResults.isNotEmpty;

  /// Record a thumbnail obtained outside the loader (e.g. read back from the
  /// cache when returning to this session).
  void recordThumbnail(String id, ThumbnailResult result) =>
      _recordThumbnail(id, result);

  /// Drop the decoded thumbnails to free memory. They are re-read from the L2
  /// cache when this session is shown again (ADR 007 決定 5 / ADR 008 決定 5).
  ///
  /// Deliberately does not fire [onChanged]: this runs from `deactivate`, i.e.
  /// during a build, where asking for a repaint throws. The view repaints when
  /// the session is shown again and the reloaded thumbnails report in.
  void releaseThumbnailResults() => _thumbnailResults.clear();

  /// Retry items whose thumbnail failed as [ThumbnailFailReason.notSupported].
  /// Called after returning from the viewer/player, when the backing data may
  /// have been cached in the meantime.
  void retryUnsupportedThumbnails() {
    thumbnails.retryUnsupported((id) {
      final result = _thumbnailResults[id];
      if (result is ThumbnailFailed &&
          result.reason == ThumbnailFailReason.notSupported) {
        _thumbnailResults.remove(id);
        return true;
      }
      return false;
    });
  }

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

  void _recordThumbnail(String id, ThumbnailResult result) {
    _thumbnailResults[id] = result;
    onChanged?.call();
  }
}
