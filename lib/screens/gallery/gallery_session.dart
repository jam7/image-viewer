import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../models/viewer_mark.dart';
import '../../services/cache/cache_manager.dart';
import 'gallery_uri.dart';
import 'gallery_uri_dialect.dart';
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

  /// What to call this place, when the URI alone cannot say — an author page
  /// shows a name the address does not carry. Empty means "ask the URI"
  /// (`placeTitle` in gallery_uri_dialect.dart).
  ///
  /// Not final, because the name may only turn up with the contents: opening
  /// an author page by typing its address, or restoring one from disk, means
  /// nobody is there to supply it up front. See [_learnTitle].
  String _title;
  String get title => _title;

  /// Called when something the tab's chrome shows about this place changes —
  /// its [title] arriving late, its [minPageCount] being narrowed. Whatever
  /// draws that is neither the loader nor the toolbar, and has no other way to
  /// hear of it.
  void Function()? onEntryChanged;

  int _minPageCount = 0;

  /// Show only items with at least this many pages; 0 for all of them.
  ///
  /// Kept per place, next to [anchor], because it is how *this* list is being
  /// looked at: going back should find the list the way it was left. It stays
  /// out of [sourceUri] because it filters what is already loaded — putting it
  /// in the address would make every change a different place, and so a
  /// refetch of a list we already have.
  int get minPageCount => _minPageCount;

  set minPageCount(int value) {
    if (value == _minPageCount) return;
    _minPageCount = value;
    _visible = null;
    onEntryChanged?.call();
  }

  List<ImageSource>? _visible;

  /// What is actually on screen: [loaded] minus the display-only filters.
  ///
  /// Here rather than on whichever widget draws it, because more than one
  /// thing walks this list — the grid, and the viewer looking for the works
  /// either side of the one it is showing (ADR 010). A filter known only to
  /// the grid would let the viewer swipe into works the grid is hiding.
  ///
  /// Held rather than recomputed: this is read on every build, and rebuilding
  /// a copy of a list thousands long while the reader is scrolling is a cost
  /// with nothing to show for it. Dropped whenever the list or the filter
  /// changes, which is the only way it can go stale.
  List<ImageSource> get visibleItems => _visible ??= _applyFilters();

  List<ImageSource> _applyFilters() {
    if (_minPageCount <= 0) return loaded;
    // "N+" means N or more.
    return loaded
        .where((i) => (i.metadata?['pageCount'] as int? ?? 1) >= _minPageCount)
        .toList();
  }

  /// Called when a thumbnail result arrives and the view should repaint.
  ///
  /// Installed by whichever view is showing this session, not by whoever built
  /// it — a session is often created by a tab opener or a navigation, far from
  /// the widget that will display it, and a session with no view needs no
  /// repaints. Page loads are awaited by the caller instead of reported here.
  void Function()? onChanged;

  /// Thumbnail engine for this session. Its `source` is [provider] and its
  /// results land in this session (see [thumbnailFor]).
  late final ThumbnailLoader thumbnails;

  final List<ImageSource> loaded = [];

  /// Where the view was scrolled to, by item rather than by pixel offset so it
  /// survives a rotation. Written by the grid as the user scrolls; read back
  /// when a view starts showing this session again.
  ScrollAnchor? anchor;

  /// The same thing for a place that is one work rather than a list: which
  /// page of it, and how far into a video. Written when the viewer goes away,
  /// which on a tab switch is every time the reader looks at something else.
  ViewerMark? mark;

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
    String title = '',
    this.path,
    bool Function(ImageSource)? thumbnailFilter,
    List<ImageSource>? seedItems,
  })  : _title = title,
        _cacheManager = cacheManager,
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

  /// Build the session for the place [uri] names, deriving from it what the
  /// caller used to spell out: which path to page through, which items get
  /// thumbnails, and whether the list is a finite local one.
  ///
  /// [provider] is the already-resolved source for [uri]'s scheme. Resolving it
  /// through the registry is the tab controller's job (2B-10) — that needs a
  /// BuildContext for the Pixiv login prompt, which does not belong here.
  factory GallerySession.fromUri(
    Uri uri, {
    required ImageSourceProvider provider,
    required CacheManager cacheManager,
    String title = '',
  }) {
    return GallerySession(
      sourceUri: uri,
      provider: provider,
      cacheManager: cacheManager,
      title: title,
      path: uri.scheme == smbUriScheme ? smbPathOf(uri) : pixivPathOf(uri),
      // SMB lists directories alongside files; they have no thumbnail.
      // The lambda needs its own parentheses or its body swallows the ternary.
      thumbnailFilter: uri.scheme == smbUriScheme
          ? ((i) => i.metadata?['isDirectory'] != true)
          : null,
    );
  }

  /// True until the first page is loaded, then true while more pages remain.
  bool get hasMore => !_firstPageLoaded || _cursor != null;

  /// Whether this session has ever fetched. False means a view showing it must
  /// kick off the first load; true means it is being revisited and already
  /// holds its items (going back must not append another page).
  bool get hasLoaded => _firstPageLoaded;
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

  /// The view showing this session went away. Stops its thumbnail work and
  /// drops the decoded results; [attach] resumes and restores both
  /// (ADR 007 決定 5 / ADR 008 決定 5).
  ///
  /// Cancelling matters as much as freeing the memory: a session nobody is
  /// looking at would otherwise keep pulling images, and the tab that *is* on
  /// screen waits behind it for the network and the disk cache.
  ///
  /// Deliberately does not fire [onChanged]: this runs from `deactivate`, i.e.
  /// during a build, where asking for a repaint throws. The repaint comes from
  /// the results [attach] reports as they land.
  void detach() {
    _attachGeneration++;
    thumbnails.cancel();
    // Only the decoded images cost memory. A recorded failure costs nothing and
    // cannot be read back from the cache, so dropping it would leave the tile
    // spinning for good: [attach] would find nothing to restore, and the loader
    // — which still counts the item as answered — would not fetch it again.
    _thumbnailResults.removeWhere((_, result) => result is ThumbnailData);
  }

  /// A view started showing this session again. Re-reads the thumbnails that
  /// [detach] dropped from the L2 cache, reporting each one as it lands so the
  /// grid fills in progressively.
  ///
  /// Only reads `thumb:` — never the full-size `full:` entry, which would put a
  /// full-resolution decode behind a grid tile.
  ///
  /// Then picks up whatever [detach] cut off. Those items are inside the
  /// dispatched range, so nothing else would ever ask for them again and they
  /// would sit as spinners for as long as the session lives.
  Future<void> attach() async {
    if (_thumbnailItems.isEmpty) return;
    final generation = ++_attachGeneration;
    // Two clocks, because they point at different fixes: [reading] is the disk,
    // and what is left is the repaint this asks for after every single item.
    final wall = Stopwatch()..start();
    final reading = Stopwatch();
    var found = 0;
    var missing = 0;
    for (final item in _thumbnailItems) {
      if (generation != _attachGeneration) return; // detached or disposed
      if (_thumbnailResults.containsKey(item.id)) continue;
      try {
        reading.start();
        final cached = await _cacheManager.get('thumb:${item.id}');
        reading.stop();
        if (cached == null) {
          missing++;
          continue;
        }
        if (generation != _attachGeneration) return;
        found++;
        _recordThumbnail(item.id, ThumbnailData(Uint8List.fromList(cached.data)));
      } catch (e, st) {
        reading.stop();
        _log.warning('thumbnail cache reload failed: ${item.name}', e, st);
      }
    }
    _log.info('attach: ${_thumbnailItems.length} items, $found restored, '
        '$missing not cached, ${wall.elapsedMilliseconds}ms '
        '(${reading.elapsedMilliseconds}ms reading)');
    if (generation != _attachGeneration) return;
    await resumeMissingThumbnails();
  }

  /// Fetch again every dispatched item this session has no result for.
  ///
  /// The loader remembers which items it has answered, but that is a different
  /// question from what the grid can paint. [detach] drops the decoded images
  /// and [attach] reads them back from the L2 cache — which may have been
  /// emptied or evicted in between, leaving the item answered by the loader and
  /// blank on screen. Going by the loader's record alone turned a whole tab
  /// into spinners after a cache clear, with only a brand new tab showing
  /// anything.
  ///
  /// A recorded [ThumbnailFailed] counts as a result, so it is not retried here
  /// (that is [retryUnsupportedThumbnails]).
  Future<void> resumeMissingThumbnails() =>
      thumbnails.retryMissing((id) => !_thumbnailResults.containsKey(id));

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
      _visible = null;
      if (firstPage) _learnTitle(page.items);

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

  /// Take the name out of the first page, for a place that arrived without one.
  ///
  /// A title supplied by whoever sent us here always wins: it was known before
  /// the fetch, so using it avoids showing the address and then replacing it.
  void _learnTitle(List<ImageSource> items) {
    if (_title.isNotEmpty) return;
    final learned = titleFromItems(sourceUri, items);
    if (learned == null) return;
    _title = learned;
    onEntryChanged?.call();
  }

  Future<void> dispose() {
    _attachGeneration++;
    onEntryChanged = null; // a page still in flight must not report back
    return thumbnails.dispose();
  }

  void _recordThumbnail(String id, ThumbnailResult result) {
    _thumbnailResults[id] = result;
    onChanged?.call();
  }
}
