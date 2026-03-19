import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/cache/cache_metadata.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/source_registry.dart';
import '../gallery/gallery_screen.dart';
import '../viewer/viewer_screen.dart';

/// お気に入り一覧タブ。全ソース横断で表示。
class FavoritesTab extends StatefulWidget {
  final FavoritesStore favoritesStore;
  final CacheManager cacheManager;
  final SourceRegistry registry;

  const FavoritesTab({
    super.key,
    required this.favoritesStore,
    required this.cacheManager,
    required this.registry,
  });

  @override
  State<FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<FavoritesTab> {
  final Map<String, Uint8List> _thumbnailData = {};

  List<FavoriteEntry> get _favorites => widget.favoritesStore.listAll();

  @override
  void initState() {
    super.initState();
    _loadThumbnails();
  }

  Future<void> _loadThumbnails() async {
    final favorites = _favorites;
    print('[FavoritesTab] Loading thumbnails for ${favorites.length} favorites');
    for (final fav in favorites) {
      if (_thumbnailData.containsKey(fav.imageId)) continue;
      try {
        final cached = await widget.cacheManager.get('thumb:${fav.imageId}')
            ?? await widget.cacheManager.get('full:${fav.imageId}');
        if (cached != null && mounted) {
          setState(() => _thumbnailData[fav.imageId] = Uint8List.fromList(cached.data));
        }
      } catch (e, st) {
        print('[FavoritesTab] thumbnail error: $e\n$st');
      }
    }
  }

  ImageSource _toImageSource(FavoriteEntry entry) {
    final typeStr = entry.sourceInfo['type'] as String?;
    final type = ImageSourceType.values.firstWhere(
      (t) => t.name == typeStr,
      orElse: () => ImageSourceType.pixiv,
    );
    return ImageSource(
      id: entry.imageId,
      name: entry.name,
      uri: entry.uri,
      type: type,
      sourceKey: entry.sourceKey,
      metadata: entry.sourceInfo,
    );
  }

  void _onItemTap(FavoriteEntry item, int index) async {
    final allFavs = _favorites;
    final imageItems = allFavs.map(_toImageSource).toList();
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(
          items: imageItems,
          initialIndex: index,
          registry: widget.registry,
          cacheManager: widget.cacheManager,
          favoritesStore: widget.favoritesStore,
        ),
      ),
    );

    if (!mounted) return;

    if (result != null && result['action'] == 'showUser') {
      await _openUserWorks(result['userId'] as int, result['userName'] as String);
    }

    // Refresh after returning (favorites may have changed)
    if (mounted) {
      setState(() {});
      _loadThumbnails();
    }
  }

  Future<void> _openUserWorks(int userId, String userName) async {
    final provider = await widget.registry.resolve('pixiv:default', context);
    if (provider == null || provider is! PixivSource) return;
    if (!mounted) return;

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        source: provider,
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        registry: widget.registry,
        initialUserPath: '/user/$userId',
        initialUserName: userName,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final favorites = _favorites;
    return Scaffold(
      appBar: AppBar(
        title: Text('お気に入り (${favorites.length})'),
      ),
      body: favorites.isEmpty
          ? const Center(child: Text('お気に入りはまだありません'))
          : GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: favorites.length,
              itemBuilder: (context, index) {
                final item = favorites[index];
                final thumbnail = _thumbnailData[item.imageId];
                return GestureDetector(
                  onTap: () => _onItemTap(item, index),
                  child: thumbnail != null
                      ? Image.memory(thumbnail, fit: BoxFit.cover)
                      : Container(
                          color: Colors.grey[300],
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.image, color: Colors.grey),
                              const SizedBox(height: 4),
                              Text(
                                item.name,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                );
              },
            ),
    );
  }
}
