import 'package:flutter/material.dart';

import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/smb/smb_config_store.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../settings/settings_screen.dart';
import 'favorites_gallery_body.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_tab_controller.dart';
import 'gallery_tab_opener.dart';
import 'gallery_uri.dart';
import 'home_gallery_body.dart';
import 'pixiv_gallery_body.dart';
import 'smb_gallery_body.dart';
import 'widgets/gallery_tab_strip.dart';
import 'widgets/gallery_toolbar.dart';

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
        final tab = controller.active;
        if (tab == null) {
          return Scaffold(
            appBar: GalleryTabStrip(
              controller: controller,
              newTabOptions: _newTabOptions(context),
            ),
            body: const Center(child: Text('タブがありません')),
          );
        }
        // Also follow the active tab's own moves: navigating happens inside the
        // body, which the controller never hears about, and the strip's label
        // has to keep up.
        return AnimatedBuilder(
          animation: tab.revision,
          builder: (context, _) => _buildActive(context, tab),
        );
      },
    );
  }

  /// The one app bar, shared by every tab. It sits here rather than inside the
  /// body so it keeps its state — most visibly its own scroll position — while
  /// the body underneath is rebuilt for each tab.
  Widget _buildActive(BuildContext context, GalleryTab tab) {
    // Keyed by tab so switching gives the new tab its own view state —
    // scroll position, loading flags — instead of inheriting the old one's.
    final key = ValueKey(tab.id);
    return Scaffold(
      appBar: _buildHeader(context, tab),
      body: switch (tab.current.sourceUri.scheme) {
        homeUriScheme => HomeGalleryBody(
            key: key,
            tab: tab,
            smbConfigStore: smbConfigStore,
            onOpenPlace: (uri, title, {bool inNewTab = false}) => inNewTab
                ? _open(context, uri, title, activate: false)
                : _goTo(context, tab, uri, title),
            onOpenSettings: () => _openSettings(context),
            // Home with nothing behind it is the floor: there is no tab to fall
            // back to and no route underneath, so back belongs to the system.
          ),
        favUriScheme => FavoritesGalleryBody(
            key: key,
            tab: tab,
            cacheManager: cacheManager,
            favoritesStore: favoritesStore,
            registry: registry,
            onOpenPlace: (uri, title, {bool inNewTab = false}) => inNewTab
                ? _open(context, uri, title, activate: false)
                : _goTo(context, tab, uri, title),
          ),
        smbUriScheme => SmbGalleryBody(
            key: key,
            tab: tab,
            onOpenInNewTab: _openInNewTab,
            cacheManager: cacheManager,
            favoritesStore: favoritesStore,
            registry: registry,
            proxyServer: proxyServer,
          ),
        _ => PixivGalleryBody(
            key: key,
            tab: tab,
            onOpenInNewTab: _openInNewTab,
            cacheManager: cacheManager,
            favoritesStore: favoritesStore,
            registry: registry,
          ),
      },
    );
  }

  /// What the `+` button offers: every configured source, plus settings.
  List<NewTabOption> _newTabOptions(BuildContext context) => [
        NewTabOption(
          label: 'ホーム',
          icon: Icons.home,
          onSelected: () =>
              controller.open(GalleryTab(homeSession(cacheManager))),
        ),
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
          label: 'お気に入り',
          icon: Icons.favorite,
          onSelected: () => _open(context, favGalleryUri(), 'お気に入り'),
        ),
        NewTabOption(
          label: '設定',
          icon: Icons.settings,
          onSelected: () => _openSettings(context),
        ),
      ];

  /// Settings is not a place: it has no URI and no tab. It goes on top of the
  /// whole set, and both ways in — the `+` menu and home's own row — land here.
  void _openSettings(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        smbConfigStore: smbConfigStore,
      ),
    ));
  }

  /// A body asking for a second tab on a place it can already reach: the
  /// provider is resolved, so this skips the registry. Opened in the background
  /// so long-pressing several folders in a row keeps you where you are.
  void _openInNewTab(GallerySession session) =>
      controller.open(GalleryTab(session), activate: false);

  /// The two header rows: the tab strip over the navigation toolbar (ADR 009).
  PreferredSizeWidget _buildHeader(BuildContext context, GalleryTab tab) {
    return GalleryHeader(
      strip: GalleryTabStrip(
        controller: controller,
        newTabOptions: _newTabOptions(context),
      ),
      toolbar: GalleryToolbar(
        tab: tab,
        // Typed in rather than followed from a link, so nothing is known about
        // the destination but its address; the name comes from getting there.
        onNavigate: (uri) => _goTo(context, tab, uri, ''),
        menuItems: _menuItems(context, tab),
      ),
    );
  }

  /// The hamburger: this tab's own places on top (2C-3 moves the Pixiv
  /// sections here), operations on the whole app below.
  List<ToolbarMenuItem> _menuItems(BuildContext context, GalleryTab tab) => [
        ToolbarMenuItem(
          label: '再読み込み',
          icon: Icons.refresh,
          onSelected: () => _reload(tab),
        ),
        ToolbarMenuItem(
          label: '設定',
          icon: Icons.settings,
          onSelected: () => _openSettings(context),
        ),
      ];

  /// Read this place again from its source. A fresh session on the same URI,
  /// keeping the scroll anchor: the reader is looking at the same list, not
  /// being sent somewhere new.
  void _reload(GalleryTab tab) {
    final current = tab.current;
    tab.replaceCurrent(GallerySession.fromUri(
      current.sourceUri,
      provider: current.provider,
      cacheManager: cacheManager,
      title: current.title,
    )..anchor = current.anchor);
  }

  /// Follow a link from inside [tab]: go there in this tab, pushing onto its
  /// history so back comes home to where it was followed from.
  ///
  /// The destination may belong to a different source than the tab is showing —
  /// the favorites list holds items from everywhere — so the session comes from
  /// the registry rather than the current session's provider. The body is
  /// picked per URI scheme, so the tab simply starts rendering the other source.
  Future<void> _goTo(
      BuildContext context, GalleryTab tab, Uri uri, String title) async {
    final session = await opener.session(uri, context, title: title);
    if (session != null) tab.navigate(session);
  }

  Future<void> _open(BuildContext context, Uri uri, String title,
      {bool activate = true}) async {
    final tab = await opener.open(uri, context, title: title);
    if (tab != null) controller.open(tab, activate: activate);
  }
}
