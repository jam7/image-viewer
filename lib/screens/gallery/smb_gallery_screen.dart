import 'package:flutter/material.dart';

import '../../models/image_source.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';
import 'widgets/gallery_view.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/smb_source.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../../widgets/thumbnail_result.dart';
import '../video/video_player_screen.dart';
import '../viewer/viewer_screen.dart';

/// SMBディレクトリブラウズ画面。
class SmbGalleryScreen extends StatefulWidget {
  final SmbSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;
  final SmbProxyServer proxyServer;
  final String initialPath;

  const SmbGalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    required this.proxyServer,
    this.initialPath = '/',
  });

  @override
  State<SmbGalleryScreen> createState() => _SmbGalleryScreenState();
}

class _SmbGalleryScreenState extends State<SmbGalleryScreen> {
  late final GalleryTab _tab;
  final _viewKey = GlobalKey<GalleryViewState>();
  GallerySession get _session => _tab.current;

  @override
  void initState() {
    super.initState();
    _tab = GalleryTab(_sessionFor(widget.initialPath));
  }

  GallerySession _sessionFor(String path) => GallerySession.fromUri(
        smbGalleryUri(widget.source.config.id, path),
        provider: widget.source,
        cacheManager: widget.cacheManager,
        title: path,
        onChanged: () {
          if (mounted) setState(() {});
        },
      );

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _onItemTap(ImageSource item) {
    if (item.metadata?['isDirectory'] == true) {
      // Descending is a navigation within this tab, not a new screen (ADR 008).
      final path = item.metadata?['path'] as String? ?? '/';
      setState(() => _tab.navigate(_sessionFor(path)));
    } else if (item.metadata?['isVideo'] == true) {
      _session.thumbnails.cancel();
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          item: item,
          source: widget.source,
          proxyServer: widget.proxyServer,
        ),
      )).then((_) {
        _session.retryUnsupportedThumbnails();
        _session.thumbnails.retryInterrupted();
      });
    } else {
      final viewerItems =
          _session.thumbnailItems.where((i) => i.metadata?['isVideo'] != true).toList();
      final index = viewerItems.indexWhere((i) => i.id == item.id);
      if (index >= 0) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ViewerScreen(
            items: viewerItems,
            initialIndex: index,
            registry: widget.registry,
            cacheManager: widget.cacheManager,
            favoritesStore: widget.favoritesStore,
          ),
        )).then((_) => _session.retryUnsupportedThumbnails());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      key: _viewKey,
      tab: _tab,
      items: _session.loaded,
      emptyMessage: 'ファイルが見つかりませんでした',
      tileBuilder: _buildTile,
      onItemsChanged: () => setState(() {}),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _viewKey.currentState?.goBack(),
        ),
        title: Text(
          _session.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context, ImageSource item, int index) {
    final isDir = item.metadata?['isDirectory'] == true;
    final isVideo = item.metadata?['isVideo'] == true;
    final thumb = _session.thumbnailFor(item.id);

    return GestureDetector(
      onTap: () => _onItemTap(item),
      child: isDir
          ? _buildIconTile(item.name, Icons.folder, Colors.amber)
          : isVideo
          ? (thumb is ThumbnailData
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(thumb.data, fit: BoxFit.cover),
                    const Center(
                      child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 48),
                    ),
                  ],
                )
              : _buildIconTile(item.name, Icons.play_circle_outline, Colors.deepPurple))
          : switch (thumb) {
              ThumbnailData(data: final d) =>
                Image.memory(d, fit: BoxFit.cover),
              ThumbnailFailed(reason: ThumbnailFailReason.notSupported) =>
                _buildIconTile(item.name, Icons.archive, Colors.blueGrey),
              ThumbnailFailed(reason: ThumbnailFailReason.timeout) =>
                _buildIconTile(item.name, Icons.broken_image, Colors.red[300]!),
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
    );
  }

  Widget _buildIconTile(String name, IconData icon, Color color) {
    return Container(
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 4),
          Text(
            name,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
