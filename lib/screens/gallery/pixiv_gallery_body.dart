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
  // Sections, searches and author pages are entries in the tab's history
  // rather than separate screens (ADR 008).
  GalleryTab get _tab => widget.tab;
  GallerySession get _session => _tab.current;
  PixivSource get _source => _session.provider as PixivSource;

  /// Opening a work is a move within this tab, not a new screen (ADR 010).
  /// The viewer finds the list it sits in by looking one entry back — which is
  /// this one — so nothing has to be handed over.
  void _openViewer(int index) {
    final item = _session.visibleItems[index];
    _log.info('openViewer: index=$index, image=${item.name}');
    setState(() => _tab.navigate(GallerySession.fromUri(
          pixivArtworkUri(item.id),
          provider: _source,
          cacheManager: widget.cacheManager,
          title: item.name,
        )));
  }

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      tab: _tab,
      emptyMessage: '画像が見つかりませんでした',
      tileBuilder: _buildTile,
      onItemsChanged: () => setState(() {}),
    );
  }

  Widget _buildTile(BuildContext context, ImageSource image, int index) {
    final thumb = _session.thumbnailFor(image);
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
