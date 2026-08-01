import 'package:flutter/material.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/source_registry.dart';
import '../../widgets/thumbnail_result.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';
import 'gallery_uri_dialect.dart';
import 'widgets/gallery_view.dart';

/// 全ソース横断のお気に入りを見せるタブの中身。
///
/// Flat by nature: there is nowhere to navigate to within it, so unlike the SMB
/// and Pixiv bodies it never adds to the tab's history. Items keep the source
/// they came from, so opening one hands the viewer an item the registry can
/// still resolve.
class FavoritesGalleryBody extends StatefulWidget {
  final GalleryTab tab;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;

  /// Go to a place this list cannot reach on its own — an author or a tag from
  /// a work being viewed. Favorites hold items from every source, so it has no
  /// provider of its own to build such a place from; resolving it, and owning
  /// the tabs, both belong above this widget.
  ///
  /// [inNewTab] false follows it like a link: this tab goes there, pushing onto
  /// its history, and back returns to the list. True opens it alongside without
  /// leaving, which is what a long press asks for.
  final void Function(Uri uri, String title, {bool inNewTab}) onOpenPlace;

  const FavoritesGalleryBody({
    super.key,
    required this.tab,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    required this.onOpenPlace,
  });

  @override
  State<FavoritesGalleryBody> createState() => _FavoritesGalleryBodyState();
}

class _FavoritesGalleryBodyState extends State<FavoritesGalleryBody> {
  GalleryTab get _tab => widget.tab;
  GallerySession get _session => _tab.current;

  /// Re-read the list. Starring happens in the viewer, so the list is stale the
  /// moment it returns; the source reads the store afresh on each page load.
  ///
  /// The replacement inherits the scroll anchor: this is the same place being
  /// re-read, not a different one, so it should not throw the reader back to
  /// the top. The anchor names an item, so it simply finds nothing to restore
  /// if that item is the one that was just un-starred.
  @override
  void initState() {
    super.initState();
    // Coming back from a work that may have been starred or unstarred there.
    // The viewer is another entry in this tab now (ADR 010), so this body is
    // rebuilt on the way back rather than resumed, and the list it holds was
    // read before any of that happened.
    if (_session.hasLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload();
      });
    }
  }

  void _reload() {
    final fresh = GallerySession.fromUri(
      _session.sourceUri,
      provider: _session.provider,
      cacheManager: widget.cacheManager,
      title: _session.title,
    )..anchor = _session.anchor;
    setState(() => _tab.replaceCurrent(fresh));
  }

  /// Looking at a starred work is a move within this tab (ADR 010). The
  /// destination belongs to whichever source the work came from, so it goes
  /// through the host — this list holds items from everywhere, and its own
  /// provider is not theirs.
  void _openViewer(int index) {
    final item = _session.visibleItems[index];
    final place = placeOf(item);
    if (place == null) return;
    widget.onOpenPlace(place, item.name);
  }

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      tab: _tab,
      emptyMessage: 'お気に入りがありません',
      tileBuilder: _buildTile,
      onItemsChanged: () => setState(() {}),
    );
  }

  Widget _buildTile(BuildContext context, ImageSource item, int index) {
    final thumb = _session.thumbnailFor(item);
    return GestureDetector(
      onTap: () => _openViewer(index),
      child: switch (thumb) {
        ThumbnailData(data: final d) => Image.memory(d, fit: BoxFit.cover),
        // A favourite whose source is not connected this run has no thumbnail
        // to fetch, only whatever was cached; say which source it wants.
        ThumbnailFailed() => _buildIconTile(item),
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

  Widget _buildIconTile(ImageSource item) {
    final scheme = item.sourceKey?.split(':').first;
    return Container(
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            scheme == smbUriScheme ? Icons.folder_shared : Icons.palette,
            size: 40,
            color: Colors.blueGrey,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              item.name,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
