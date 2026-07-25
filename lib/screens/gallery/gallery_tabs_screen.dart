import 'package:flutter/material.dart';

import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/smb/smb_config_store.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../settings/settings_screen.dart';
import 'gallery_tab_controller.dart';
import 'gallery_tab_opener.dart';
import 'gallery_uri.dart';
import 'pixiv_gallery_body.dart';
import 'smb_gallery_body.dart';
import 'widgets/gallery_tab_strip.dart';

/// Hosts the open tabs (ADR 008): one route, whose app bar is the tab strip and
/// whose body is whatever the active tab points at.
///
/// Tabs cross sources, so the source-specific part cannot be the route — the
/// body is chosen per tab from its URI scheme, and the provider it needs is
/// already on the tab's session.
class GalleryTabsScreen extends StatelessWidget {
  final GalleryTabController controller;
  final GalleryTabOpener opener;
  final SmbConfigStore smbConfigStore;
  final SmbProxyServer proxyServer;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;

  const GalleryTabsScreen({
    super.key,
    required this.controller,
    required this.opener,
    required this.smbConfigStore,
    required this.proxyServer,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final strip = GalleryTabStrip(
          controller: controller,
          newTabOptions: _newTabOptions(context),
        );
        final tab = controller.active;
        if (tab == null) {
          return Scaffold(
            appBar: strip,
            body: const Center(child: Text('タブがありません')),
          );
        }
        // Keyed by tab so switching gives the new tab its own view state —
        // scroll position, loading flags — instead of inheriting the old one's.
        final key = ValueKey(tab.id);
        return switch (tab.current.sourceUri.scheme) {
          smbUriScheme => SmbGalleryBody(
              key: key,
              tab: tab,
              appBar: strip,
              cacheManager: cacheManager,
              favoritesStore: favoritesStore,
              registry: registry,
              proxyServer: proxyServer,
            ),
          _ => PixivGalleryBody(
              key: key,
              tab: tab,
              appBar: strip,
              cacheManager: cacheManager,
              favoritesStore: favoritesStore,
              registry: registry,
            ),
        };
      },
    );
  }

  /// What the `+` button offers: every configured source, plus settings.
  List<NewTabOption> _newTabOptions(BuildContext context) => [
        NewTabOption(
          label: 'Pixiv',
          icon: Icons.palette,
          onSelected: () => _open(context, pixivGalleryUri('/top'), 'Pixiv'),
        ),
        for (final config in smbConfigStore.listAll())
          NewTabOption(
            label: config.name,
            icon: Icons.folder_shared,
            onSelected: () => _open(
              context,
              smbGalleryUri(config.id, config.basePath ?? '/'),
              config.name,
            ),
          ),
        NewTabOption(
          label: '設定',
          icon: Icons.settings,
          onSelected: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SettingsScreen(
              cacheManager: cacheManager,
              favoritesStore: favoritesStore,
              smbConfigStore: smbConfigStore,
            ),
          )),
        ),
      ];

  Future<void> _open(BuildContext context, Uri uri, String title) async {
    final tab = await opener.open(uri, context, title: title);
    if (tab != null) controller.open(tab);
  }
}
