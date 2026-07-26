import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/smb/smb_config_store.dart';
import '../../services/platform/host_activity.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../settings/settings_screen.dart';
import 'favorites_gallery_body.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_tab_controller.dart';
import 'gallery_tab_opener.dart';
import 'gallery_uri.dart';
import 'gallery_uri_dialect.dart';
import 'home_gallery_body.dart';
import 'pixiv_gallery_body.dart';
import 'smb_gallery_body.dart';
import 'viewer_gallery_body.dart';
import 'widgets/gallery_chrome.dart';
import 'widgets/gallery_tab_strip.dart';
import 'widgets/gallery_toolbar.dart';

/// Hosts the open tabs (ADR 008): one route, whose app bar is the tab strip and
/// whose body is whatever the active tab points at.
///
/// Tabs cross sources, so the source-specific part cannot be the route — the
/// body is chosen per tab from its URI scheme, and the provider it needs is
/// already on the tab's session.
class GalleryTabsScreen extends StatefulWidget {
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
  State<GalleryTabsScreen> createState() => _GalleryTabsScreenState();
}

class _GalleryTabsScreenState extends State<GalleryTabsScreen> {
  /// Whether the two header rows are showing. Owned here because they are, and
  /// set from the list being scrolled, which is several widgets down
  /// (`GalleryChrome` carries it there).
  final _chromeVisible = ValueNotifier(true);

  /// The place the header was last shown for, so that arriving somewhere new
  /// can bring it back. Folding is the business of whatever is being scrolled,
  /// but unfolding cannot be: a viewer or the home page has no list to scroll,
  /// and a header folded away by the grid you just left would stay away.
  Uri? _shownFor;

  @override
  void initState() {
    super.initState();
    _chromeVisible.addListener(_applySystemBars);
  }

  GalleryTabController get controller => widget.controller;
  GalleryTabOpener get opener => widget.opener;
  SmbConfigStore get smbConfigStore => widget.smbConfigStore;
  SmbProxyServer get proxyServer => widget.proxyServer;
  CacheManager get cacheManager => widget.cacheManager;
  FavoritesStore get favoritesStore => widget.favoritesStore;
  SourceRegistry get registry => widget.registry;

  @override
  void dispose() {
    _chromeVisible.removeListener(_applySystemBars);
    _chromeVisible.dispose();
    super.dispose();
  }

  /// The status and navigation bars go with the app's own header, but only
  /// where hiding them is the point.
  ///
  /// A grid folds its header away for room and keeps the bars; a work fills
  /// the screen. Deciding it here, from the place the tab is on, is what keeps
  /// the bars from being left hidden after moving somewhere they belong — the
  /// viewer is an entry in a tab now, not a screen with an exit to undo it on
  /// (ADR 010 決定 7).
  /// Whether the bars should be out of the way: a work is showing and the
  /// header is already away. A grid folds its header for room and keeps them.
  bool get _immersive =>
      _shownFor != null && itemOf(_shownFor!) != null && !_chromeVisible.value;

  void _applySystemBars() {
    final immersive = _immersive;
    // Both, because neither covers everything: SystemChrome is the right call
    // and is a no-op on Android 15 (see HostActivity.setImmersive), while the
    // channel exists only there.
    SystemChrome.setEnabledSystemUIMode(
      immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    const HostActivity().setImmersive(immersive);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final tab = controller.active;
        if (tab == null) {
          return _scaffold(
            context,
            header: GalleryTabStrip(
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

  /// The whole screen: the shared header over whichever body the active tab
  /// calls for.
  ///
  /// The header is built here rather than inside the body so it keeps its
  /// state — most visibly the strip's own scroll position — while the body
  /// underneath is rebuilt for each tab.
  ///
  /// It is a row of the page rather than `Scaffold.appBar` because it folds
  /// away as the list is read (ADR 009): an app bar's height is fixed at the
  /// moment the Scaffold is built, so animating it would mean rebuilding the
  /// whole screen, body and all, on every frame of the fold.
  Widget _buildActive(BuildContext context, GalleryTab tab) {
    _showChromeOnArrival(tab.current.sourceUri);
    return _scaffold(
      context,
      header: _buildHeader(context, tab),
      body: _bodyFor(context, tab),
    );
  }

  void _showChromeOnArrival(Uri place) {
    if (_shownFor == place) return;
    // Reading on through a folder is one activity, not a series of arrivals:
    // moving from one work to the next keeps whatever the reader chose, so a
    // picture put full screen stays that way for the one after it.
    final stillReading = _shownFor != null &&
        itemOf(_shownFor!) != null &&
        itemOf(place) != null;
    _shownFor = place;
    if (stillReading) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _chromeVisible.value = true;
      _applySystemBars(); // no change to listen for when it was already true
    });
  }

  /// Which body shows this tab's place.
  ///
  /// An address that names an item rather than a list is the viewer's,
  /// whatever source it came from (ADR 010); asking the dialect keeps this out
  /// of the business of reading paths and extensions. Everything else goes by
  /// scheme.
  ///
  /// Keyed by tab so switching gives the new tab its own view state — scroll
  /// position, loading flags — instead of inheriting the old one's.
  Widget _bodyFor(BuildContext context, GalleryTab tab) {
    final key = ValueKey(tab.id);
    final uri = tab.current.sourceUri;
    if (itemOf(uri) != null) {
      return ViewerGalleryBody(
        key: key,
        tab: tab,
        cacheManager: cacheManager,
        favoritesStore: favoritesStore,
        registry: registry,
        onOpenInNewTab: _openInNewTab,
      );
    }
    return switch (uri.scheme) {
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
    };
  }

  /// The page: header on top, body below, and the shared say-so about whether
  /// the header is showing carried down to whatever is doing the scrolling.
  ///
  /// The status bar is kept clear here, not inside the strip, so that folding
  /// the header away does not send the grid up under the clock.
  Widget _scaffold(BuildContext context,
      {required Widget header, required Widget body}) {
    return Scaffold(
      body: GalleryChrome(
        visible: _chromeVisible,
        child: ValueListenableBuilder<bool>(
          valueListenable: _chromeVisible,
          builder: (context, _, child) => SafeArea(
            // Hiding the bars is not enough on its own: the room kept for them
            // is ours to give back, and a picture that stops short of the top
            // of the screen is not full screen.
            top: !_immersive,
            bottom: false,
            child: child!,
          ),
          child: Column(
            children: [
              GalleryChromeSlot(visible: _chromeVisible, child: header),
              Expanded(child: body),
            ],
          ),
        ),
      ),
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
        menuGroups: _menuGroups(context, tab),
      ),
    );
  }

  /// The hamburger: this tab's own places on top, operations on the whole app
  /// below. Which places those are is the source's business, so it comes from
  /// the URI dialect rather than from a scheme test here.
  ///
  /// `+` stays what it was — open a *new* tab — so the two never overlap.
  List<List<ToolbarMenuItem>> _menuGroups(
          BuildContext context, GalleryTab tab) =>
      [
        [
          for (final place in sectionsOf(tab.current.sourceUri))
            ToolbarMenuItem(
              label: place.label,
              icon: Icons.chevron_right,
              onSelected: () => _goTo(context, tab, place.uri, ''),
            ),
        ],
        [
          ToolbarMenuItem(
            label: 'アドレスをコピー',
            icon: Icons.link,
            onSelected: () => _copyAddress(context, tab),
          ),
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
        ],
      ];

  /// Take this place with you — into another tab, a note, a message.
  ///
  /// Its own entry rather than a side effect of tapping the window: editing
  /// where you are and carrying it elsewhere are different errands, and the
  /// window now offers whichever of the two is worth typing over (the search
  /// word, usually), which is not always something that can be pasted back.
  /// Copied raw, so it always reads back as this exact place.
  void _copyAddress(BuildContext context, GalleryTab tab) {
    Clipboard.setData(ClipboardData(text: '${tab.current.sourceUri}'));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('アドレスをコピーしました'),
        duration: Duration(seconds: 2),
      ),
    );
  }

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
