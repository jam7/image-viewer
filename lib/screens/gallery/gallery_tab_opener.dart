import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/source_registry.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';

final _log = Logger('GalleryTabOpener');

/// Turns a URI into an open tab, which is the half of URI-driven creation that
/// [GallerySession.fromUri] deliberately left out: resolving the source needs
/// the registry, and Pixiv may put a login screen up first, so it needs a
/// BuildContext and has to be awaited.
class GalleryTabOpener {
  final SourceRegistry registry;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;

  const GalleryTabOpener({
    required this.registry,
    required this.cacheManager,
    required this.favoritesStore,
  });

  /// Open [uri] as a new tab, or null if the source could not be resolved
  /// (login cancelled, server gone). [title] labels the tab where the URI
  /// cannot say it — an author's name, a server's nickname.
  Future<GalleryTab?> open(
    Uri uri,
    BuildContext context, {
    String title = '',
  }) async {
    final key = sourceKeyOf(uri);
    final provider = await registry.resolve(key, context);
    if (provider == null) {
      _log.info('could not resolve $key for $uri');
      return null;
    }
    return GalleryTab(GallerySession.fromUri(
      uri,
      provider: provider,
      cacheManager: cacheManager,
      title: title,
    ));
  }
}
