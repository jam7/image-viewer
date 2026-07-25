import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';
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

  /// The user asked to go back. Passed straight to [GalleryView]; the host
  /// walks the tab's history.
  final VoidCallback? onBack;

  /// Back at this tab's first entry. Passed straight to [GalleryView]; the
  /// host decides whether that closes the tab or leaves the gallery.
  final VoidCallback? onExitTab;

  const PixivGalleryBody({
    super.key,
    required this.tab,
    this.onBack,
    this.onExitTab,
    required this.onOpenInNewTab,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
  });

  @override
  State<PixivGalleryBody> createState() => _PixivGalleryBodyState();
}

class _PixivGalleryBodyState extends State<PixivGalleryBody> {
  final _searchController = TextEditingController();
  final _filterController = TextEditingController();
  /// Lets the filter ask the view to top up when it narrows the list, and the
  /// back affordances route through the view's history-aware handler.
  final _viewKey = GlobalKey<GalleryViewState>();
  int _minPageCount = 0;

  // Search options (session-only). Apply to tag searches.
  String _searchMode = 's_tag_full'; // s_tag_full=完全一致 / s_tag=部分一致
  String _searchOrder = 'date_d'; // date_d=新着 / date=古い順

  // Sections, searches and author pages are entries in the tab's history
  // rather than separate screens (ADR 008).
  GalleryTab get _tab => widget.tab;
  GallerySession get _session => _tab.current;
  PixivSource get _source => _session.provider as PixivSource;

  /// Where the tab currently is, which is what the URI of its entry says.
  String get _path => pixivPathOf(_session.sourceUri);

  bool get _isSearchPage => _path.startsWith('/search');

  /// Items shown in the grid: loaded items minus the page-count (`>N`) filter.
  List<ImageSource> get _visibleItems => _filterImages(_session.loaded);

  void _applyFilter() {
    final text = _filterController.text.trim();
    // Accept both ">10" and plain "10"
    final match = RegExp(r'>?(\d+)').firstMatch(text);
    _minPageCount = match != null ? int.parse(match.group(1)!) : 0;
  }

  List<ImageSource> _filterImages(List<ImageSource> images) {
    if (_minPageCount <= 0) return images;
    return images.where((img) {
      final pageCount = img.metadata?['pageCount'] as int? ?? 1;
      return pageCount > _minPageCount;
    }).toList();
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

  /// Run [action] once the viewer's pop has settled; navigating mid-pop fights
  /// the route transition.
  void _afterViewer(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  /// A search path carrying the current tag-match / order toggles.
  String _searchPathFor(String word) =>
      '/search?word=${Uri.encodeComponent(word)}'
      '&s_mode=$_searchMode&order=$_searchOrder';

  @override
  void initState() {
    super.initState();
    // Reflect how the tab's current search was issued, so the toggles agree
    // with the results on screen.
    if (_isSearchPage) {
      final q = Uri.parse('https://dummy$_path').queryParameters;
      _searchController.text = q['word'] ?? '';
      _searchMode = q['s_mode'] ?? _searchMode;
      _searchOrder = q['order'] ?? _searchOrder;
    }
    _log.info('initState: path=$_path, tab=${_tab.id}');
  }

  @override
  void dispose() {
    _searchController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  /// Pixiv URLを解析して内部パスに変換。
  /// - https://www.pixiv.net/artworks/12345 → 作品を直接開く
  /// - https://www.pixiv.net/ajax/illust/12345/pages → 作品を直接開く
  /// - https://www.pixiv.net/users/12345 → /user/12345
  String? _parsePixivUrl(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null || !uri.host.contains('pixiv.net')) return null;

    // /artworks/{id}
    final artworkMatch = RegExp(r'/artworks/(\d+)').firstMatch(uri.path);
    if (artworkMatch != null) {
      return '/artworks/${artworkMatch.group(1)}';
    }

    // /ajax/illust/{id}/pages or /ajax/illust/{id}
    final ajaxMatch = RegExp(r'/ajax/illust/(\d+)').firstMatch(uri.path);
    if (ajaxMatch != null) {
      return '/artworks/${ajaxMatch.group(1)}';
    }

    // /users/{id}
    final userMatch = RegExp(r'/users/(\d+)').firstMatch(uri.path);
    if (userMatch != null) {
      return '/user/${userMatch.group(1)}';
    }

    return null;
  }

  /// Reload the same place (search options changed, favorites edited). Not a
  /// navigation, so it swaps the history entry rather than adding one. The view
  /// reloads when it sees the new session.
  void _reload() {
    final path = _isSearchPage
        ? _searchPathFor(
            Uri.parse('https://dummy$_path').queryParameters['word'] ?? '')
        : _path;
    setState(() => _tab.replaceCurrent(_sessionFor(path)));
  }



  void _onSearch() {
    final input = _searchController.text.trim();
    final parsed = _parsePixivUrl(input);

    // /artworks/{id}: open viewer directly
    if (parsed != null && parsed.startsWith('/artworks/')) {
      final id = parsed.substring('/artworks/'.length);
      final source = ImageSource(
        id: id,
        name: 'Artwork $id',
        uri: '',
        type: ImageSourceType.pixiv,
        sourceKey: 'pixiv:default',
        metadata: {'illustId': int.parse(id)},
      );
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ViewerScreen(
          items: [source],
          registry: widget.registry,
          cacheManager: widget.cacheManager,
          favoritesStore: widget.favoritesStore,
          onOpenAuthorInNewTab: _openAuthorAlongside,
          onOpenTagSearchInNewTab: _openTagSearchAlongside,
        ),
      ));
      return;
    }

    // Otherwise go to the results within this tab, carrying the options.
    _navigate(parsed ?? _searchPathFor(input));
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
      _afterViewer(() => _navigate('/user/$userId', authorName: userName));
    } else if (result != null && result['action'] == 'searchTag') {
      final tag = result['tag'] as String;
      _afterViewer(() {
        _searchController.text = tag;
        _navigate(_searchPathFor(tag));
      });
    }
  }

  /// Label for the Pixiv page at [path], fixed at session creation because the
  /// author name is known only at the moment we navigate there.
  static String _titleFor(String path, String? authorName) {
    if (path.startsWith('/search')) return '検索結果一覧';
    if (path.startsWith('/user/')) return '${authorName ?? ""} の作品';
    if (path == '/bookmarks') return 'ブックマーク一覧';
    if (path == '/favorites') return 'お気に入り';
    return 'Pixiv';
  }

  /// A way to jump elsewhere in Pixiv. Labelled rather than a bare icon, which
  /// nobody found — but with a fixed label, since the tab chip already says
  /// which page this is and repeating it here only costs width.
  Widget _buildSectionMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Pixiv のページ',
      onSelected: _navigate,
      itemBuilder: (_) => const [
        PopupMenuItem(value: '/top', child: Text('トップ')),
        PopupMenuItem(value: '/bookmarks', child: Text('ブックマーク')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.only(left: 10),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Pixiv', style: TextStyle(fontWeight: FontWeight.w600)),
            Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  /// Cycle the tag-match mode (完全 <-> 部分). Reloads if on a search page.
  void _toggleSearchMode() {
    setState(() {
      _searchMode = _searchMode == 's_tag_full' ? 's_tag' : 's_tag_full';
    });
    if (_isSearchPage) _reload();
  }

  /// Cycle the order (新着 <-> 古い順). Reloads if on a search page.
  void _toggleSearchOrder() {
    setState(() {
      _searchOrder = _searchOrder == 'date_d' ? 'date' : 'date_d';
    });
    if (_isSearchPage) _reload();
  }

  /// Re-apply the page-count (`>N`) filter to the already-loaded items. It is a
  /// display-only filter, so no refetch — but load more if the view got short.
  void _onFilterChanged() {
    setState(_applyFilter);
    _viewKey.currentState?.fillViewport();
  }

  Widget _buildFilterBar() {
    final optionButtonStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 48),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          _buildSectionMenu(),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'タグ or URL...',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _onSearch,
                ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onSubmitted: (_) => _onSearch(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: TextField(
              controller: _filterController,
              decoration: const InputDecoration(
                hintText: '>N',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8),
              ),
              onSubmitted: (_) => _onFilterChanged(),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _toggleSearchMode,
            style: optionButtonStyle,
            child: Text(_searchMode == 's_tag_full' ? '完全' : '部分'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _toggleSearchOrder,
            style: optionButtonStyle,
            child: Text(_searchOrder == 'date_d' ? '新着' : '古い順'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      key: _viewKey,
      tab: _tab,
      items: _visibleItems,
      emptyMessage: '画像が見つかりませんでした',
      tileBuilder: _buildTile,
      header: _buildFilterBar(),
      onBack: widget.onBack,
      onExitTab: widget.onExitTab,
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
