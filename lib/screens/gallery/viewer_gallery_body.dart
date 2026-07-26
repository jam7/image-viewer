import 'package:flutter/material.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/source_registry.dart';
import '../viewer/viewer_screen.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';
import 'gallery_uri_dialect.dart';
import 'system_back.dart';
import 'widgets/gallery_chrome.dart';

/// The list [item] sits in as seen from [tab], and where in it — or the item
/// on its own when the tab cannot say.
///
/// The entry behind the current one is the list the viewer was opened from,
/// but only when it actually holds this item: an address pasted into a tab
/// sitting on an unrelated place has no neighbourhood, and neither has one
/// opened in a tab of its own.
///
/// Items the app cannot be *at* are left out — an SMB directory is a list
/// rather than something to look at, and swiping onto one would be a move to
/// nowhere. [placeOf] returning null is what says so.
({List<ImageSource> items, int index}) neighbourhood(
  GalleryTab tab,
  ImageSource item,
) {
  if (tab.index > 0) {
    final list = tab.history[tab.index - 1].visibleItems
        .where((i) => placeOf(i) != null)
        .toList();
    final at = list.indexWhere((i) => i.id == item.id);
    if (at >= 0) return (items: list, index: at);
  }
  return (items: [item], index: 0);
}

/// One work, shown as a place in a tab (ADR 010).
///
/// The viewer needs a list to move along, and does not get one: the tab's
/// history already holds it, because the entry behind this one is the list
/// this work was opened from. Reading it from there rather than from the
/// address is what keeps a work's address short enough to paste.
///
/// The entry behind counts only when it actually contains this work. Paste an
/// address into a tab sitting on an unrelated folder and that folder is not
/// its neighbourhood — the work then stands alone, with nothing either side,
/// which is also what happens in a brand new tab.
class ViewerGalleryBody extends StatelessWidget {
  final GalleryTab tab;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;

  /// Open a place in a new tab. Tabs are owned above this widget, so it asks.
  final void Function(GallerySession session) onOpenInNewTab;

  const ViewerGalleryBody({
    super.key,
    required this.tab,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    required this.onOpenInNewTab,
  });

  GallerySession get _session => tab.current;

  /// Move to another work in the list: a change of address, not a move to a
  /// new place. Pushing here would bury the list under every work read on the
  /// way, and turn one step back into forty (ADR 010 決定 3).
  void _goToItem(ImageSource item) {
    final place = placeOf(item);
    if (place == null) return;
    tab.replaceCurrent(
      GallerySession.fromUri(
        place,
        provider: _session.provider,
        cacheManager: cacheManager,
        title: item.name,
      ),
    );
  }

  /// The address turned out to name a list. Swap this entry for the list, so
  /// the reader lands where they were going instead of on a failure.
  void _showAsList() {
    final list = listAt(_session.sourceUri);
    if (list == null) return;
    tab.replaceCurrent(GallerySession.fromUri(
      list,
      provider: _session.provider,
      cacheManager: cacheManager,
    ));
  }

  static String _searchPath(String tag) => pixivPathOf(pixivSearchUri(tag));

  void _openPixivPlace(String path, String title) => tab.navigate(
    GallerySession.fromUri(
      pixivGalleryUri(path),
      provider: _session.provider,
      cacheManager: cacheManager,
      title: title,
    ),
  );

  void _openPixivPlaceAlongside(String path, String title) => onOpenInNewTab(
    GallerySession.fromUri(
      pixivGalleryUri(path),
      provider: _session.provider,
      cacheManager: cacheManager,
      title: title,
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The header above belongs to the host, and follows the viewer's own
    // overlay: reading a picture means seeing the picture.
    final chrome = GalleryChrome.maybeOf(context);
    // Only ever built for an address that names an item — that is how the host
    // picked this body over a grid.
    final item = itemOf(_session.sourceUri)!;
    final here = neighbourhood(tab, item);
    // The author and tag chips are Pixiv's, and so is the source that would
    // have to serve what they lead to. On anything else they never appear —
    // wiring them anyway would build a Pixiv place on an SMB source.
    final pixiv = _session.sourceUri.scheme == pixivUriScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleSystemBack(tab, () {});
      },
      child: ViewerScreen(
        items: here.items,
        index: here.index,
        onIndexChanged: (i) => _goToItem(here.items[i]),
        onClose: tab.back,
        onNotAnItem: _showAsList,
        onOverlayChanged: (show) => chrome?.value = show,
        onShowAuthor: pixiv
            ? (userId, userName) =>
                  _openPixivPlace('/user/$userId', pixivAuthorTitle(userName))
            : null,
        onSearchTag: pixiv
            ? (tag) => _openPixivPlace(_searchPath(tag), '')
            : null,
        onOpenAuthorInNewTab: pixiv
            ? (userId, userName) => _openPixivPlaceAlongside(
                '/user/$userId',
                pixivAuthorTitle(userName),
              )
            : null,
        onOpenTagSearchInNewTab: pixiv
            ? (tag) => _openPixivPlaceAlongside(_searchPath(tag), '')
            : null,
        registry: registry,
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
      ),
    );
  }
}
