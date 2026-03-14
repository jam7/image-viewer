import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../settings/settings_screen.dart';
import '../viewer/viewer_screen.dart';

/// サムネイル一覧画面。
class GalleryScreen extends StatefulWidget {
  final PixivSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;

  const GalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

enum _PixivTab { recommended, bookmarks, search }

class _GalleryScreenState extends State<GalleryScreen> {
  final List<ImageSource> _images = [];
  final Map<String, Uint8List> _thumbnailData = {};
  bool _isLoading = false;
  String? _error;
  _PixivTab _currentTab = _PixivTab.recommended;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadImages();
  }

  @override
  void dispose() {
    _searchController.dispose();
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

  String get _currentPath {
    switch (_currentTab) {
      case _PixivTab.recommended:
        return '/recommended';
      case _PixivTab.bookmarks:
        return '/bookmarks';
      case _PixivTab.search:
        final word = _searchController.text.trim();
        return word.isEmpty ? '/recommended' : '/search?word=$word';
    }
  }

  Future<void> _loadImages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    widget.source.resetPagination();
    _images.clear();
    _thumbnailData.clear();

    try {
      final images = await widget.source.listImages(path: _currentPath);
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _loadThumbnails(images);
    } catch (e) {
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
      final images = await widget.source.listImages(path: _currentPath);
      setState(() {
        _images.addAll(images);
        _isLoading = false;
      });
      _loadThumbnails(images);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
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
      } catch (_) {
        // サムネイル取得失敗は無視
      }
    }
  }

  void _onTabChanged(_PixivTab tab) {
    if (_currentTab == tab) return;
    _currentTab = tab;
    _loadImages();
  }

  void _onSearch() {
    _currentTab = _PixivTab.search;
    _loadImages();
  }

  void _openViewer(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerScreen(
        initialImage: _images[index],
        source: widget.source,
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
      ),
    ));
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Pixiv'),
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
              _tabButton('検索', _PixivTab.search),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (_currentTab == _PixivTab.search)
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'タグを検索...',
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(child: _buildGrid()),
        ],
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
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _images.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _images.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final image = _images[index];
        final thumbnail = _thumbnailData[image.id];

        return GestureDetector(
          onTap: () => _openViewer(index),
          child: thumbnail != null
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
        );
      },
    );
  }
}
