import 'package:flutter/material.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/source_registry.dart';
import '../../widgets/thumbnail_result.dart';
import '../viewer/viewer_screen.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';
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

  /// The user asked to go back. Passed straight to [GalleryView]; the host
  /// walks the tab's history.
  final VoidCallback? onBack;

  /// Back at this tab's first entry. Passed straight to [GalleryView]; the
  /// host decides whether that closes the tab or leaves the gallery.
  final VoidCallback? onExitTab;

  const FavoritesGalleryBody({
    super.key,
    required this.tab,
    this.onBack,
    this.onExitTab,
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
  void _reload() {
    final fresh = GallerySession.fromUri(
      _session.sourceUri,
      provider: _session.provider,
      cacheManager: widget.cacheManager,
      title: _session.title,
    )..anchor = _session.anchor;
    setState(() => _tab.replaceCurrent(fresh));
  }

  /// Search options are the Pixiv screen's own state, which this list has no
  /// view of, so a tag opened from here uses the defaults.
  Uri _tagSearch(String tag) =>
      pixivGalleryUri('/search?word=${Uri.encodeComponent(tag)}'
          '&s_mode=s_tag_full&order=date_d');

  Future<void> _openViewer(int index) async {
    final items = _session.loaded;
    final result =
        await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
      builder: (_) => ViewerScreen(
        items: items,
        initialIndex: index,
        registry: widget.registry,
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        // Long-press: open alongside and let the reader keep their page.
        onOpenAuthorInNewTab: (id, name) => widget
            .onOpenPlace(pixivGalleryUri('/user/$id'), '$name の作品',
                inNewTab: true),
        onOpenTagSearchInNewTab: (tag) =>
            widget.onOpenPlace(_tagSearch(tag), tag, inNewTab: true),
      ),
    ));
    if (!mounted) return;

    // Re-read before going anywhere: starring happens in the viewer, and this
    // list is what a later back comes home to.
    _reload();

    // A tap hands the request back by closing. Following it is a navigation
    // within this tab, the same as tapping a folder in the SMB list — which is
    // the point of the list being a tab at all.
    if (result != null && result['action'] == 'showUser') {
      _afterViewer(() => widget.onOpenPlace(
            pixivGalleryUri('/user/${result['userId']}'),
            '${result['userName']} の作品',
          ));
    } else if (result != null && result['action'] == 'searchTag') {
      final tag = result['tag'] as String;
      _afterViewer(() => widget.onOpenPlace(_tagSearch(tag), tag));
    }
  }

  /// Run [action] after the frame the viewer's pop is settling in, so the
  /// navigation does not land in the middle of the route transition.
  void _afterViewer(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GalleryView(
      tab: _tab,
      items: _session.loaded,
      emptyMessage: 'お気に入りがありません',
      tileBuilder: _buildTile,
      onBack: widget.onBack,
      onExitTab: widget.onExitTab,
      onItemsChanged: () => setState(() {}),
    );
  }

  Widget _buildTile(BuildContext context, ImageSource item, int index) {
    final thumb = _session.thumbnailFor(item.id);
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
