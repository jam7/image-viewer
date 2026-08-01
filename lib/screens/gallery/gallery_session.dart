import '../../models/image_source.dart';
import '../../models/viewer_mark.dart';
import '../../services/cache/cache_manager.dart';
import 'gallery_uri.dart';
import 'gallery_uri_dialect.dart';
import '../../services/sources/image_source_provider.dart';
import '../../services/thumbnail/thumbnail_scheduler.dart';
import '../../widgets/thumbnail_result.dart';
import 'scroll_anchor.dart';

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

  /// Answers this place's requests for thumbnails, nearest first (ADR 011).
  late final ThumbnailScheduler _scheduler;

  final List<ImageSource> loaded = [];

  /// Where the view was scrolled to, by item rather than by pixel offset so it
  /// survives a rotation. Written by the grid as the user scrolls; read back
  /// when a view starts showing this session again.
  ScrollAnchor? anchor;

  /// The same thing for a place that is one work rather than a list: which
  /// page of it, and how far into a video. Written when the viewer goes away,
  /// which on a tab switch is every time the reader looks at something else.
  ViewerMark? mark;

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
    String title = '',
    this.path,
    List<ImageSource>? seedItems,
  })  : _title = title,
        _cacheManager = cacheManager,
        _seedItems = seedItems {
    _scheduler = ThumbnailScheduler(
      cache: cacheManager,
      pool: cacheManager.thumbnails,
      source: provider,
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
      // Nothing here about which items get thumbnails: a directory tile draws
      // a folder and never asks, so the filter that used to keep directories
      // out of the batches has nothing left to keep them out of.
    );
  }

  /// True until the first page is loaded, then true while more pages remain.
  bool get hasMore => !_firstPageLoaded || _cursor != null;

  /// Whether this session has ever fetched. False means a view showing it must
  /// kick off the first load; true means it is being revisited and already
  /// holds its items (going back must not append another page).
  bool get hasLoaded => _firstPageLoaded;
  bool get isLoadingPage => _loadingPage;

  /// The thumbnail for [item], asking for it if there is none (ADR 011).
  ///
  /// Painting is what asks. There is no record of what has been handed out and
  /// no watermark into the list — a tile that can paint does, and a tile that
  /// cannot has just said so. That is what makes an emptied cache recover by
  /// itself: the next paint asks again, because nothing is claiming the
  /// question was already answered.
  ThumbnailResult? thumbnailFor(ImageSource item, {int distance = 0}) {
    final held = _cacheManager.thumbnails.get(item.id);
    if (held != null) return held;
    _scheduler.want(item, distance: distance);
    return null;
  }

  /// Ask ahead for the band around what is on screen, so that scrolling meets
  /// thumbnails already there. [near] is what is visible; [around] is the
  /// screen either side of it.
  void wantBand(List<ImageSource> near, List<ImageSource> around) {
    for (final item in near) {
      thumbnailFor(item);
    }
    for (final item in around) {
      thumbnailFor(item, distance: 1);
    }
    final wanted = {...near.map((i) => i.id), ...around.map((i) => i.id)};
    _scheduler.keepOnly(wanted.contains);
  }

  /// The view showing this session went away.
  ///
  /// Only stops work. Nothing is dropped and nothing has to be restored when a
  /// view comes back: what was fetched is in the pool, which outlives both
  /// (ADR 011). This is all that is left of the pair of methods that used to
  /// throw every decoded thumbnail away here and read them all back there.
  ///
  /// Cancelling still matters: a place nobody is looking at would otherwise go
  /// on pulling images, and the place that *is* on screen would wait behind it.
  ///
  /// Deliberately does not fire [onChanged]: this runs from `deactivate`, i.e.
  /// during a build, where asking for a repaint throws.
  void detach() => _scheduler.cancel();

  /// Stop making stills while the source is busy playing something, and pick
  /// up again afterwards.
  void pauseThumbnails() => _scheduler.pauseStills();
  void resumeThumbnails() => _scheduler.resumeStills();

  /// Ask again for the items [test] selects, by forgetting the answer held for
  /// them: the next paint finds nothing and asks. How a retry is spelled when
  /// there is no ledger — used after a viewer visit, where a file that had no
  /// thumbnail may now have its bytes in the cache.
  void forgetThumbnails(bool Function(ThumbnailResult result) test) =>
      _cacheManager.thumbnails.removeWhere((_, result) => test(result));

  /// Load the next page (the first page if none yet) and append it to
  /// [loaded]. Returns the new items (empty if a load is already running or
  /// the list is exhausted).
  ///
  /// Nothing is said about thumbnails here: a page that has arrived but is not
  /// on screen is not wanted yet, and asking for it is the grid's business.
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
    onEntryChanged = null; // a page still in flight must not report back
    return _scheduler.dispose();
  }

  /// The scheduler has already put it in the pool; this is only the repaint.
  void _recordThumbnail(String id, ThumbnailResult result) => onChanged?.call();
}
