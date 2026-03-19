import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/image_source.dart';
import 'gallery_constants.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/source_registry.dart';
import '../viewer/viewer_screen.dart';

/// サムネイル一覧画面。
class GalleryScreen extends StatefulWidget {
  final PixivSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;
  final String? initialUserPath;
  final String? initialUserName;

  const GalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    this.initialUserPath,
    this.initialUserName,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

enum _PixivTab { recommended, bookmarks, favorites, search }

class _GalleryScreenState extends State<GalleryScreen> {
  final List<ImageSource> _images = [];
  final Map<String, Uint8List> _thumbnailData = {};
  bool _isLoading = false;
  String? _error;
  _PixivTab _currentTab = _PixivTab.recommended;
  final _searchController = TextEditingController();
  final _filterController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  int _minPageCount = 0;

  void _applyFilter() {
    final text = _filterController.text.trim();
    final match = RegExp(r'>(\d+)').firstMatch(text);
    _minPageCount = match != null ? int.parse(match.group(1)!) : 0;
  }

  List<ImageSource> _filterImages(List<ImageSource> images) {
    if (_minPageCount <= 0) return images;
    return images.where((img) {
      final pageCount = img.metadata?['pageCount'] as int? ?? 1;
      return pageCount > _minPageCount;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    if (widget.initialUserPath != null) {
      _userPath = widget.initialUserPath;
      _userName = widget.initialUserName;
    }
    _loadImages();
  }

  @override
  void deactivate() {
    _thumbnailData.clear();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // Reload thumbnails from cache only (deactivate cleared them)
    if (_images.isNotEmpty && _thumbnailData.isEmpty) {
      _reloadThumbnailsFromCache();
    }
  }

  Future<void> _reloadThumbnailsFromCache() async {
    for (final image in _images) {
      if (_thumbnailData.containsKey(image.id)) continue;
      try {
        final cached = await widget.cacheManager.get('thumb:${image.id}')
            ?? await widget.cacheManager.get('full:${image.id}');
        if (cached != null && mounted) {
          setState(() => _thumbnailData[image.id] = Uint8List.fromList(cached.data));
        }
      } catch (e, st) {
        print('[Gallery] reloadThumbnail error: $e\n$st');
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

    return KeyEventResult.ignored;
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        widget.source.hasNextPage) {
      _loadMore();
    }
  }

  String? _userPath; // /user/{id} で作者ページを表示中の場合

  String get _currentPath {
    if (_userPath != null) return _userPath!;
    switch (_currentTab) {
      case _PixivTab.recommended:
        return '/recommended';
      case _PixivTab.bookmarks:
        return '/bookmarks';
      case _PixivTab.favorites:
        return '/favorites'; // ローカル処理、APIは呼ばない
      case _PixivTab.search:
        final word = _searchController.text.trim();
        if (word.isEmpty) return '/recommended';
        final parsed = _parsePixivUrl(word);
        if (parsed != null) return parsed;
        return '/search?word=$word';
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

  String? _userName;

  /// 作者ページをギャラリーで表示。
  void showUserWorks(int userId, String userName) {
    setState(() {
      _userPath = '/user/$userId';
      _userName = userName;
      _images.clear();
      _thumbnailData.clear();
    });
    widget.source.resetPagination();
    _loadImages();
  }

  void _clearUserPath() {
    if (_userPath != null) {
      setState(() {
        _userPath = null;
        _userName = null;
      });
    }
  }

  Future<void> _loadImages() async {
    _applyFilter();
    setState(() {
      _isLoading = true;
      _error = null;
    });

    widget.source.resetPagination();
    _images.clear();
    _thumbnailData.clear();

    // お気に入りタブはローカルデータから読み込み
    if (_currentTab == _PixivTab.favorites && _userPath == null) {
      final entries = widget.favoritesStore.listAll();
      final images = _filterImages(entries.map((e) => ImageSource(
        id: e.imageId,
        name: e.name,
        uri: e.uri,
        type: ImageSourceType.pixiv,
        metadata: {
          ...e.sourceInfo,
          'thumbnailUrl': e.thumbnailUrl,
        },
      )).toList());
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _loadThumbnails(images);
      return;
    }

    try {
      final images = _filterImages(
        await widget.source.listImages(path: _currentPath),
      );
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _loadThumbnails(images);
      _loadMoreIfNeeded();
    } catch (e, st) {
      print('[Gallery] loadImages error: $e\n$st');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final images = _filterImages(
        await widget.source.listImages(path: _currentPath),
      );
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _loadThumbnails(images);
      _loadMoreIfNeeded();
    } catch (e, st) {
      print('[Gallery] loadMore error: $e\n$st');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// コンテンツが画面に収まってスクロールできない場合、追加読み込みする
  void _loadMoreIfNeeded() {
    if (!widget.source.hasNextPage) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0) {
        _loadMore();
      }
    });
  }

  Future<void> _loadThumbnails(List<ImageSource> images) async {
    for (final image in images) {
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
            () => widget.source.fetchThumbnail(image),
          );
          if (mounted) {
            setState(() =>
                _thumbnailData[image.id] = Uint8List.fromList(result.data));
          }
        }
      } catch (e, st) {
        print('[Gallery] thumbnail error (${image.name}): $e\n$st');
      }
    }
  }

  void _onTabChanged(_PixivTab tab) {
    if (_currentTab == tab && _userPath == null) return;
    _currentTab = tab;
    _clearUserPath();
    _loadImages();
  }

  void _onSearch() {
    _clearUserPath();
    _currentTab = _PixivTab.search;

    final input = _searchController.text.trim();
    final parsed = _parsePixivUrl(input);

    // /artworks/{id} の場合は直接ビューアを開く
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

    _loadImages();
  }

  void _openViewer(int index) async {
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
    if (result != null && result['action'] == 'showUser') {
      showUserWorks(result['userId'] as int, result['userName'] as String);
    } else if (_currentTab == _PixivTab.favorites) {
      // ビューアでお気に入りが変更された可能性があるので再読み込み
      _loadImages();
    }
  }

  void _openSettings() {
    Navigator.of(context).pop(); // Back to home
  }

  void _onBackNavigation() {
    _clearUserPath();
    _loadImages();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton && _userPath != null) {
      _onBackNavigation();
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      leading: _userPath != null
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _onBackNavigation,
            )
          : null,
      title: Text(
        _userName != null ? '$_userName の作品' : 'Pixiv',
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: _openSettings,
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Row(
          children: [
            _tabButton('おすすめ', _PixivTab.recommended),
            _tabButton('ブックマーク', _PixivTab.bookmarks),
            _tabButton('お気に入り', _PixivTab.favorites),
            _tabButton('検索', _PixivTab.search),
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
          if (_currentTab == _PixivTab.search)
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
          if (_currentTab == _PixivTab.search)
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
          onHorizontalDragEnd: _userPath != null
              ? (details) {
                  if ((details.primaryVelocity ?? 0) > 300) {
                    _onBackNavigation();
                  }
                }
              : null,
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

  Widget _tabButton(String label, _PixivTab tab) {
    final isSelected = _currentTab == tab;
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

    return GridView.builder(
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
    );
  }
}
