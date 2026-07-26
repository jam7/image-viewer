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

/// SMB ディレクトリを見せるタブの中身。The tab and the app bar come from the
/// host screen, which owns them across every source.
class SmbGalleryBody extends StatefulWidget {
  final GalleryTab tab;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;
  final SmbProxyServer proxyServer;

  /// Open a place in a new tab. Tabs are owned above this widget, so it asks.
  final void Function(GallerySession session) onOpenInNewTab;

  const SmbGalleryBody({
    super.key,
    required this.tab,
    required this.onOpenInNewTab,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    required this.proxyServer,
  });

  @override
  State<SmbGalleryBody> createState() => _SmbGalleryBodyState();
}

class _SmbGalleryBodyState extends State<SmbGalleryBody> {
  GalleryTab get _tab => widget.tab;
  GallerySession get _session => _tab.current;
  SmbSource get _source => _session.provider as SmbSource;

  GallerySession _sessionFor(String path) => GallerySession.fromUri(
        smbGalleryUri(_source.config.id, path),
        provider: _source,
        cacheManager: widget.cacheManager,
        // No title: a directory is named by its own address, and the URI
        // dialect already says so (gallery_uri_dialect.dart). Only the
        // server's nickname needs carrying, and that is set when the tab opens.
      );

  void _onItemTap(ImageSource item) {
    if (item.metadata?['isDirectory'] == true) {
      // Descending is a navigation within this tab, not a new screen (ADR 008).
      setState(() => _tab.navigate(_sessionFor(_pathOf(item))));
    } else if (item.metadata?['isVideo'] == true) {
      _session.thumbnails.cancel();
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          item: item,
          source: _source,
          proxyServer: widget.proxyServer,
        ),
      )).then((_) {
        _session.retryUnsupportedThumbnails();
        _session.resumeMissingThumbnails();
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

  static String _pathOf(ImageSource item) =>
      item.metadata?['path'] as String? ?? '/';

  /// Long-pressing a folder opens it alongside instead of moving there.
  void _onItemLongPress(ImageSource item) {
    if (item.metadata?['isDirectory'] != true) return;
    widget.onOpenInNewTab(_sessionFor(_pathOf(item)));
  }

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      tab: _tab,
      items: _session.loaded,
      emptyMessage: 'ファイルが見つかりませんでした',
      tileBuilder: _buildTile,
      onItemsChanged: () => setState(() {}),
    );
  }

  Widget _buildTile(BuildContext context, ImageSource item, int index) {
    final isDir = item.metadata?['isDirectory'] == true;
    final isVideo = item.metadata?['isVideo'] == true;
    final thumb = _session.thumbnailFor(item.id);

    return GestureDetector(
      onTap: () => _onItemTap(item),
      onLongPress: isDir ? () => _onItemLongPress(item) : null,
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
