import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';
import 'gallery_uri_dialect.dart';
import 'widgets/gallery_view.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/source_registry.dart';
import '../../widgets/thumbnail_result.dart';
import '../viewer/viewer_screen.dart';

final _log = Logger('Gallery');

/// Pixiv のページを見せるタブの中身。The tab and the app bar come from the host
/// screen, which owns them across every source.
class PixivGalleryBody extends StatefulWidget {
  final GalleryTab tab;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;

  /// Open a place in a new tab. Tabs are owned above this widget, so it asks.
  final void Function(GallerySession session) onOpenInNewTab;

  const PixivGalleryBody({
    super.key,
    required this.tab,
    required this.onOpenInNewTab,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
  });

  @override
  State<PixivGalleryBody> createState() => _PixivGalleryBodyState();
}

class _PixivGalleryBodyState extends State<PixivGalleryBody> {
  /// Lets the filter ask the view to top up when it narrows the list, and the
  /// back affordances route through the view's history-aware handler.
  final _viewKey = GlobalKey<GalleryViewState>();

  /// The narrowing already reflected on screen, so a change made in the
  /// toolbar can be noticed here — the widget itself carries no filter.
  int _shownMinPageCount = 0;

  // Sections, searches and author pages are entries in the tab's history
  // rather than separate screens (ADR 008).
  GalleryTab get _tab => widget.tab;
  GallerySession get _session => _tab.current;
  PixivSource get _source => _session.provider as PixivSource;

  /// Where the tab currently is, which is what the URI of its entry says.
  String get _path => pixivPathOf(_session.sourceUri);

  /// Items shown in the grid: loaded items minus the page-count filter, which
  /// belongs to the place being looked at rather than to this widget (the
  /// button that sets it is in the toolbar, a screen apart from here).
  List<ImageSource> get _visibleItems {
    final min = _session.minPageCount;
    if (min <= 0) return _session.loaded;
    // "N+" means N or more. It used to mean more than N, which read the same
    // in a text box but not on a button labelled 3+.
    return _session.loaded
        .where((img) => (img.metadata?['pageCount'] as int? ?? 1) >= min)
        .toList();
  }

  /// Build the session for the Pixiv page at [path]. Favorites are a finite
  /// local list (seedItems); other pages page through the source via loadPage.
  /// [authorName] is the one label the URI cannot carry.
  GallerySession _sessionFor(String path, {String? authorName}) {
    return GallerySession.fromUri(
      pixivGalleryUri(path),
      provider: _source,
      cacheManager: widget.cacheManager,
      title: _titleFor(path, authorName),
    );
  }

  /// Go to [path] within this tab. Back returns to where we were.
  void _navigate(String path, {String? authorName}) {
    setState(() =>
        _tab.navigate(_sessionFor(path, authorName: authorName)));
  }

  /// Open a place in a second tab while the viewer stays up. The reader asked
  /// for "alongside", so they keep the page they are on.
  void _openAuthorAlongside(int userId, String userName) => widget
      .onOpenInNewTab(_sessionFor('/user/$userId', authorName: userName));

  void _openTagSearchAlongside(String tag) =>
      widget.onOpenInNewTab(_sessionFor(_searchPathFor(tag)));

  /// A tag search as issued from where this tab is, so a search being refined
  /// keeps its 完全一致 / 並び順. The Pixiv dialect always has an answer.
  String _searchPathFor(String tag) =>
      pixivPathOf(searchFrom(_session.sourceUri, tag)!);

  /// Run [action] after this frame, if we are still here. Callers say why they
  /// need to wait — a route transition to finish, a layout to settle.
  void _nextFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  @override
  void initState() {
    super.initState();
    _shownMinPageCount = _session.minPageCount;
    _log.info('initState: path=$_path, tab=${_tab.id}');
  }

  /// The toolbar narrowed (or widened) the list. Rebuilding shows the right
  /// items, but a narrowed grid can end up shorter than the viewport, and then
  /// nothing is left to ask for the next page — so top it up.
  @override
  void didUpdateWidget(PixivGalleryBody old) {
    super.didUpdateWidget(old);
    if (_shownMinPageCount == _session.minPageCount) return;
    _shownMinPageCount = _session.minPageCount;
    _nextFrame(() => _viewKey.currentState?.fillViewport());
  }

  void _openViewer(int index) async {
    final items = _visibleItems;
    _log.info('openViewer: index=$index, image=${items[index].name}');
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(
          items: items,
          initialIndex: index,
          registry: widget.registry,
          cacheManager: widget.cacheManager,
          favoritesStore: widget.favoritesStore,
          onOpenAuthorInNewTab: _openAuthorAlongside,
          onOpenTagSearchInNewTab: _openTagSearchAlongside,
        ),
      ),
    );
    _log.info('viewer returned: result=$result, mounted=$mounted');
    if (!mounted) return;
    if (result != null && result['action'] == 'showUser') {
      final userId = result['userId'] as int;
      final userName = result['userName'] as String;
      _nextFrame(() => _navigate('/user/$userId', authorName: userName));
    } else if (result != null && result['action'] == 'searchTag') {
      final tag = result['tag'] as String;
      _nextFrame(() => _navigate(_searchPathFor(tag)));
    }
  }

  /// The one label for the Pixiv page at [path] that its address cannot
  /// supply: the author's name, when whoever sent us here already knew it.
  ///
  /// Everything else is left empty on purpose, so the URI dialect answers
  /// instead (gallery_uri_dialect.dart) — including the author's name when it
  /// was not known in advance, which the session takes out of the first page.
  /// Passing it here still matters: it is the difference between the name
  /// being there from the start and a number that changes once the page lands.
  static String _titleFor(String path, String? authorName) =>
      authorName != null && path.startsWith('/user/')
          ? pixivAuthorTitle(authorName)
          : '';

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      key: _viewKey,
      tab: _tab,
      items: _visibleItems,
      emptyMessage: '画像が見つかりませんでした',
      tileBuilder: _buildTile,
      onItemsChanged: () => setState(() {}),
    );
  }

  Widget _buildTile(BuildContext context, ImageSource image, int index) {
    final thumb = _session.thumbnailFor(image.id);
    final pageCount = image.metadata?['pageCount'] as int? ?? 1;

    return GestureDetector(
      onTap: () => _openViewer(index),
      child: Stack(
        fit: StackFit.expand,
        children: [
          switch (thumb) {
            ThumbnailData(data: final d) => Image.memory(d, fit: BoxFit.cover),
            ThumbnailFailed() => Container(
                color: Colors.grey[300],
                child: Icon(Icons.broken_image, color: Colors.red[300]),
              ),
            null => Container(
                color: Colors.grey[300],
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          },
          if (pageCount > 1) _pageCountBadge(pageCount),
        ],
      ),
    );
  }

  /// Bottom-right "N pages" badge for multi-page works.
  Widget _pageCountBadge(int pageCount) {
    return Positioned(
      right: 4,
      bottom: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.layers, color: Colors.white, size: 12),
            const SizedBox(width: 2),
            Text(
              '$pageCount',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
