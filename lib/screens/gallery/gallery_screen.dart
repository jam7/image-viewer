import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import 'gallery_constants.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/source_registry.dart';
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
  final PixivTab initialTab;
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
    this.initialTab = PixivTab.top,
    this.initialSearchWord,
    this.initialFilterText,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

enum PixivTab { top, bookmarks, favorites }

/// Per-tab state: independent source, images, thumbnails, and scroll position.
class _TabState {
  final PixivSource source;
  final List<ImageSource> images = [];
  final Map<String, Uint8List> thumbnails = {};
  double scrollOffset = 0;
  int loadGeneration = 0;
  bool hasLoaded = false; // true after first load

  _TabState({required this.source});

  void clearThumbnails() {
    thumbnails.clear();
  }
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool _isLoading = false;
  String? _error;
  late PixivTab _currentTab;
  final _searchController = TextEditingController();
  final _filterController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  int _minPageCount = 0;

  /// Per-tab state. Created lazily on first switch.
  late final Map<PixivTab, _TabState> _tabStates;

  /// Current tab state shortcut.
  _TabState get _tab => _tabStates[_currentTab]!;

  // Convenience accessors that delegate to current _TabState
  List<ImageSource> get _images => _tab.images;
  Map<String, Uint8List> get _thumbnailData => _tab.thumbnails;
  int get _loadGeneration => _tab.loadGeneration;

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

  bool get _isUserWorksPage => widget.initialUserPath != null;

  @override
  void initState() {
    super.initState();
    _currentTab = widget.initialTab;
    _log.info('initState: initialTab=${widget.initialTab}, isUserWorks=$_isUserWorksPage, initialUserPath=${widget.initialUserPath}');
    if (widget.initialSearchWord != null) {
      _searchController.text = widget.initialSearchWord!;
    }
    if (widget.initialFilterText != null) {
      _filterController.text = widget.initialFilterText!;
      _applyFilter();
    }
    _scrollController.addListener(_onScroll);

    if (_isUserWorksPage) {
      // User works page: all tabs share the same _TabState instance
      // since tab switching only shows/hides the search field.
      final shared = _TabState(source: widget.source);
      _tabStates = {
        for (final tab in PixivTab.values) tab: shared,
      };
    } else {
      // Each tab gets its own PixivSource for independent pagination
      _tabStates = {
        for (final tab in PixivTab.values)
          tab: _TabState(
            source: PixivSource(client: widget.source.client),
          ),
      };
    }

    _loadImages();
  }

  @override
  void deactivate() {
    // Save scroll position before deactivation
    if (_scrollController.hasClients) {
      _tab.scrollOffset = _scrollController.offset;
    }
    // Clear ALL tabs' thumbnails to release memory
    var totalCleared = 0;
    for (final state in _tabStates.values) {
      totalCleared += state.thumbnails.length;
      state.clearThumbnails();
    }
    _log.info('deactivate: cleared $totalCleared thumbnails across ${_tabStates.length} tabs');
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _log.info('activate: ${_images.length} images, ${_thumbnailData.length} thumbnails cached');
    // Reload current tab's thumbnails from cache
    if (_images.isNotEmpty && _thumbnailData.isEmpty) {
      _reloadThumbnailsFromCache();
    }
  }

  Future<void> _reloadThumbnailsFromCache() async {
    final generation = _loadGeneration;
    for (final image in _images) {
      if (!mounted || generation != _loadGeneration) return;
      if (_thumbnailData.containsKey(image.id)) continue;
      try {
        final cached = await widget.cacheManager.get('thumb:${image.id}');
        if (cached != null && mounted) {
          setState(() => _thumbnailData[image.id] = Uint8List.fromList(cached.data));
        }
      } catch (e, st) {
        _log.warning('reloadThumbnail error', e, st);
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _filterController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    _scrollController.animateTo(
      (_scrollController.offset + delta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // TextFieldにフォーカスがある時はキーナビゲーション無効
    if (FocusManager.instance.primaryFocus != _focusNode) {
      return KeyEventResult.ignored;
    }

    // ScrollControllerがまだアタッチされていない場合はスキップ
    if (!_scrollController.hasClients) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(100);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-100);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _scrollBy(viewportHeight * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _scrollBy(-viewportHeight * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _scrollBy(-_scrollController.offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _scrollBy(_scrollController.position.maxScrollExtent -
          _scrollController.offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _tab.source.hasNextPage) {
      _loadMore();
    }
  }

  String get _currentPath {
    if (_isUserWorksPage) return widget.initialUserPath!;
    switch (_currentTab) {
      case PixivTab.top:
        return '/top';
      case PixivTab.bookmarks:
        return '/bookmarks';
      case PixivTab.favorites:
        return '/favorites'; // Local only, no API call
    }
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

  Future<void> _loadImages() async {
    if (!mounted) return;
    _tab.loadGeneration++;
    _applyFilter();
    setState(() {
      _isLoading = true;
      _error = null;
    });

    _tab.source.resetPagination();
    _images.clear();
    _thumbnailData.clear();

    if (_currentTab == PixivTab.favorites && !_isUserWorksPage) {
      final entries = widget.favoritesStore.listAll();
      final images = _filterImages(entries.map((e) => ImageSource(
        id: e.imageId,
        name: e.name,
        uri: e.uri,
        type: ImageSourceType.pixiv,
        sourceKey: e.sourceKey,
        metadata: {
          ...e.sourceInfo,
          'thumbnailUrl': e.thumbnailUrl,
        },
      )).toList());
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _tab.hasLoaded = true;
      _loadThumbnails(images);
      return;
    }

    try {
      final images = _filterImages(
        await _tab.source.listImages(path: _currentPath),
      );
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _tab.hasLoaded = true;
      _loadThumbnails(images);
      _loadMoreIfNeeded();
    } catch (e, st) {
      _log.warning('loadImages error', e, st);
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading) return;
    final generation = _loadGeneration;
    setState(() => _isLoading = true);

    try {
      final images = _filterImages(
        await _tab.source.listImages(path: _currentPath),
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _loadThumbnails(images);
      _loadMoreIfNeeded();
    } catch (e, st) {
      _log.warning('loadMore error', e, st);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// コンテンツが画面に収まってスクロールできない場合、追加読み込みする
  void _loadMoreIfNeeded() {
    if (!_tab.source.hasNextPage) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0) {
        _loadMore();
      }
    });
  }

  Future<void> _loadThumbnails(List<ImageSource> images) async {
    final generation = _loadGeneration;
    for (final image in images) {
      if (!mounted || generation != _loadGeneration) return;
      if (_thumbnailData.containsKey(image.id)) continue;
      final key = 'thumb:${image.id}';
      try {
        final cached = await widget.cacheManager.get(key);
        if (cached != null) {
          if (mounted) {
            setState(
                () => _thumbnailData[image.id] = Uint8List.fromList(cached.data));
          }
        } else {
          final result = await widget.cacheManager.fetchAndCache(
            key,
            () => _tab.source.fetchThumbnail(image),
          );
          if (mounted) {
            setState(() =>
                _thumbnailData[image.id] = Uint8List.fromList(result.data));
          }
        }
      } catch (e, st) {
        _log.warning('thumbnail error (id=${image.id}, name=${image.name}, uri=${image.uri})', e, st);
      }
    }
  }

  void _pushGalleryTab(PixivTab tab, {String? searchWord}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        source: PixivSource(client: widget.source.client),
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        registry: widget.registry,
        initialTab: tab,
        initialSearchWord: searchWord,
        initialFilterText: _filterController.text.trim().isNotEmpty ? _filterController.text.trim() : null,
      ),
    ));
  }

  void _onTabChanged(PixivTab tab) {
    if (_currentTab == tab && !_isUserWorksPage) return;
    if (_isUserWorksPage) {
      _pushGalleryTab(tab);
      return;
    }

    // Save current tab's scroll position
    if (_scrollController.hasClients) {
      _tab.scrollOffset = _scrollController.offset;
    }

    setState(() {
      _currentTab = tab;
      _error = null;
    });

    if (_tab.hasLoaded) {
      // Tab already loaded: restore thumbnails from cache if needed
      if (_images.isNotEmpty && _thumbnailData.isEmpty) {
        _reloadThumbnailsFromCache();
      }
      // Restore scroll position after build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_tab.scrollOffset);
        }
      });
    } else {
      _loadImages();
    }
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

    // Push a new gallery screen with search results
    final searchPath = parsed ?? '/search?word=${Uri.encodeComponent(input)}';
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
    _log.info('openViewer: index=$index, image=${_images[index].name}');
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(
          items: _images,
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
    } else if (_currentTab == PixivTab.favorites) {
      // ビューアでお気に入りが変更された可能性があるので再読み込み
      _loadImages();
    }
  }


  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      Navigator.of(context).pop();
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Text(
        _isUserWorksPage
            ? '${widget.initialUserName ?? ""} の作品'
            : 'Pixiv',
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Row(
          children: [
            _tabButton('トップ', PixivTab.top),
            _tabButton('ブックマーク', PixivTab.bookmarks),
            _tabButton('お気に入り', PixivTab.favorites),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
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
            width: 80,
            child: TextField(
              controller: _filterController,
              decoration: const InputDecoration(
                hintText: '>N',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8),
              ),
              onSubmitted: (_) => _loadImages(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 300) {
              Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: _buildAppBar(),
            body: Column(
              children: [
                _buildFilterBar(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                Expanded(child: _buildGrid()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String label, PixivTab tab) {
    final isSelected = !_isUserWorksPage && _currentTab == tab;
    return Expanded(
      child: InkWell(
        onTap: () => _onTabChanged(tab),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    if (_images.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_images.isEmpty && !_isLoading) {
      return const Center(child: Text('画像が見つかりませんでした'));
    }

    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(4),
        gridDelegate: galleryGridDelegate,
        itemCount: _images.length + (_isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _images.length) {
            return const Center(child: CircularProgressIndicator());
          }
          final image = _images[index];
          final thumbnail = _thumbnailData[image.id];
          final pageCount = image.metadata?['pageCount'] as int? ?? 1;

          return GestureDetector(
            onTap: () => _openViewer(index),
            child: Stack(
              fit: StackFit.expand,
              children: [
                thumbnail != null
                    ? Image.memory(thumbnail, fit: BoxFit.cover)
                    : Container(
                        color: Colors.grey[300],
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                if (pageCount > 1)
                  Positioned(
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
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
