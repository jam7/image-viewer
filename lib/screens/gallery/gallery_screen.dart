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

/// サムネイル一覧画面。
class GalleryScreen extends StatefulWidget {
  final PixivSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;
  final String? initialUserPath;
  final String? initialUserName;
  final String? initialSearchWord;
  final String? initialFilterText;

  const GalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    this.initialUserPath,
    this.initialUserName,
    this.initialSearchWord,
    this.initialFilterText,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _searchController = TextEditingController();
  final _filterController = TextEditingController();
  /// Lets the filter ask the view to top up when it narrows the list.
  final _viewKey = GlobalKey<GalleryViewState>();
  int _minPageCount = 0;

  // Search options (session-only). Apply to tag searches.
  String _searchMode = 's_tag_full'; // s_tag_full=完全一致 / s_tag=部分一致
  String _searchOrder = 'date_d'; // date_d=新着 / date=古い順

  // Single-page state (one Pixiv page per screen; sections/search/author are
  // reached by pushing a new screen and navigating back — ADR 007). The page's
  // items / cursor / thumbnail loader live in the GallerySession.
  late final GalleryTab _tab;
  GallerySession get _session => _tab.current;

  bool get _isSearchPage => _path.startsWith('/search');
  bool get _isFavoritesPage => _path == '/favorites';

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

  /// Build a fresh tab for the current [_path]. Favorites are a finite local
  /// list (seedItems); other pages page through the shared source via loadPage.
  GallerySession _createSession() {
    return GallerySession.fromUri(
      pixivGalleryUri(_path),
      provider: widget.source,
      cacheManager: widget.cacheManager,
      favoritesStore: widget.favoritesStore,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// The Pixiv path this screen shows. Defaults to the top page. Search paths
  /// are rebuilt with the current tag-match / order toggles.
  String get _path {
    final p = widget.initialUserPath ?? '/top';
    if (p.startsWith('/search')) {
      final word = Uri.parse('https://dummy$p').queryParameters['word'] ?? '';
      return '/search?word=${Uri.encodeComponent(word)}'
          '&s_mode=$_searchMode&order=$_searchOrder';
    }
    return p;
  }

  @override
  void initState() {
    super.initState();
    _log.info('initState: path=$_path, initialUserPath=${widget.initialUserPath}');
    if (widget.initialSearchWord != null) {
      _searchController.text = widget.initialSearchWord!;
    }
    // Seed the toggles from the search path if it carries options (so the
    // results screen reflects how the search was issued).
    final initialPath = widget.initialUserPath;
    if (initialPath != null && initialPath.startsWith('/search')) {
      final q = Uri.parse('https://dummy$initialPath').queryParameters;
      _searchMode = q['s_mode'] ?? _searchMode;
      _searchOrder = q['order'] ?? _searchOrder;
    }
    if (widget.initialFilterText != null) {
      _filterController.text = widget.initialFilterText!;
      _applyFilter();
    }
    _tab = GalleryTab(_createSession());
  }

  @override
  void dispose() {
    _tab.dispose();
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

  void _pushUserWorks(int userId, String userName) {
    _log.info('pushUserWorks: userId=$userId, userName=$userName');
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        source: PixivSource(client: widget.source.client),
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        registry: widget.registry,
        initialUserPath: '/user/$userId',
        initialUserName: userName,
        initialSearchWord: _searchController.text.trim().isNotEmpty ? _searchController.text.trim() : null,
        initialFilterText: _filterController.text.trim().isNotEmpty ? _filterController.text.trim() : null,
      ),
    ));
  }

  /// Reload the same place (search options changed, favorites edited). Not a
  /// navigation, so it swaps the history entry rather than adding one. The view
  /// reloads when it sees the new session.
  void _reload() {
    setState(() => _tab.replaceCurrent(_createSession()));
  }

  /// Push a new gallery screen for a Pixiv section (top / bookmarks / favorites),
  /// reached from the AppBar menu. Each screen is one navigable page (ADR 007).
  void _pushPage(String path) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        source: PixivSource(client: widget.source.client),
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        registry: widget.registry,
        initialUserPath: path,
        initialFilterText: _filterController.text.trim().isNotEmpty
            ? _filterController.text.trim()
            : null,
      ),
    ));
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
        ),
      ));
      return;
    }

    // Push a new gallery screen with search results, carrying the options.
    final searchPath = parsed ??
        '/search?word=${Uri.encodeComponent(input)}'
            '&s_mode=$_searchMode&order=$_searchOrder';
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        source: PixivSource(client: widget.source.client),
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        registry: widget.registry,
        initialSearchWord: input,
        initialFilterText: _filterController.text.trim().isNotEmpty ? _filterController.text.trim() : null,
        initialUserPath: searchPath,
      ),
    ));
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
        ),
      ),
    );
    _log.info('viewer returned: result=$result, mounted=$mounted');
    if (!mounted) return;
    if (result != null && result['action'] == 'showUser') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pushUserWorks(result['userId'] as int, result['userName'] as String);
      });
    } else if (_isFavoritesPage) {
      // ビューアでお気に入りが変更された可能性があるので再読み込み
      _reload();
    }
  }

  String _appBarTitle() {
    if (_isSearchPage) return '検索結果一覧';
    if (_path.startsWith('/user/')) return '${widget.initialUserName ?? ""} の作品';
    if (_path == '/bookmarks') return 'ブックマーク一覧';
    if (_path == '/favorites') return 'お気に入り';
    return 'Pixiv';
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Text(
        _appBarTitle(),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      actions: [
        PopupMenuButton<String>(
          onSelected: _pushPage,
          itemBuilder: (_) => const [
            PopupMenuItem(value: '/top', child: Text('トップ')),
            PopupMenuItem(value: '/bookmarks', child: Text('ブックマーク')),
            PopupMenuItem(value: '/favorites', child: Text('お気に入り')),
          ],
        ),
      ],
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
      session: _session,
      items: _visibleItems,
      emptyMessage: '画像が見つかりませんでした',
      tileBuilder: _buildTile,
      appBar: _buildAppBar(),
      header: _buildFilterBar(),
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
