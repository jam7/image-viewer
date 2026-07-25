import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/sources/image_source_provider.dart';
import '../../services/thumbnail/thumbnail_loader.dart';
import '../../widgets/thumbnail_result.dart';
import 'gallery_constants.dart';
import 'scroll_anchor.dart';

final _log = Logger('GallerySession');

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
  final CacheManager _cacheManager;

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

  /// Where the view was scrolled to, by item rather than by pixel offset so it
  /// survives a rotation. Written by the grid as the user scrolls; read back
  /// when a view starts showing this session again.
  ScrollAnchor? anchor;

  /// Items fed to [thumbnails] = [loaded] minus filtered-out items (e.g.
  /// directories). Same order the loader batches over, so callers can map an
  /// item to its loader index (for the batch trigger) or build a viewer list.
  final List<ImageSource> _thumbnailItems = [];
  List<ImageSource> get thumbnailItems => _thumbnailItems;

  /// item id → its position in [_thumbnailItems], kept in step as pages are
  /// appended. Lets a view go from the item it is painting to the loader's
  /// index without scanning the list on every tile.
  final Map<String, int> _thumbnailIndex = {};

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
  /// Bumped by [detach] and [dispose] so an in-flight [attach] stops.
  int _attachGeneration = 0;

  GallerySession({
    required this.sourceUri,
    required this.provider,
    required CacheManager cacheManager,
    this.path,
    this.onChanged,
    bool Function(ImageSource)? thumbnailFilter,
    List<ImageSource>? seedItems,
  })  : _cacheManager = cacheManager,
        _thumbnailFilter = thumbnailFilter ?? ((_) => true),
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

  /// Whether painting [item] should kick off the next thumbnail batch — i.e.
  /// the view has scrolled past what has been dispatched. Items with no
  /// thumbnail of their own (directories) answer false, since they are absent
  /// from the index and a missing index reads as "before the dispatched range".
  bool needsBatchFor(ImageSource item) =>
      thumbnails.needsBatch(_thumbnailIndex[item.id] ?? -1);

  bool get hasThumbnailResults => _thumbnailResults.isNotEmpty;

  /// The view showing this session went away. Drops the decoded thumbnails to
  /// free memory; [attach] brings them back (ADR 007 決定 5 / ADR 008 決定 5).
  ///
  /// Deliberately does not fire [onChanged]: this runs from `deactivate`, i.e.
  /// during a build, where asking for a repaint throws. The repaint comes from
  /// the results [attach] reports as they land.
  void detach() {
    _attachGeneration++;
    _thumbnailResults.clear();
  }

  /// A view started showing this session again. Re-reads the thumbnails that
  /// [detach] dropped from the L2 cache, reporting each one as it lands so the
  /// grid fills in progressively.
  ///
  /// Only reads `thumb:` — never the full-size `full:` entry, which would put a
  /// full-resolution decode behind a grid tile.
  Future<void> attach() async {
    if (_thumbnailItems.isEmpty || _thumbnailResults.isNotEmpty) return;
    final generation = ++_attachGeneration;
    for (final item in _thumbnailItems) {
      if (generation != _attachGeneration) return; // detached or disposed
      if (_thumbnailResults.containsKey(item.id)) continue;
      try {
        final cached = await _cacheManager.get('thumb:${item.id}');
        if (cached == null) continue;
        if (generation != _attachGeneration) return;
        _recordThumbnail(item.id, ThumbnailData(Uint8List.fromList(cached.data)));
      } catch (e, st) {
        _log.warning('thumbnail cache reload failed: ${item.name}', e, st);
      }
    }
  }

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
      for (final item in eligible) {
        _thumbnailIndex[item.id] = _thumbnailItems.length;
        _thumbnailItems.add(item);
      }
      return page.items;
    } finally {
      _loadingPage = false;
    }
  }

  Future<void> dispose() {
    _attachGeneration++;
    return thumbnails.dispose();
  }

  void _recordThumbnail(String id, ThumbnailResult result) {
    _thumbnailResults[id] = result;
    onChanged?.call();
  }
}
