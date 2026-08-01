import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'screens/gallery/gallery_tab.dart';
import 'screens/gallery/gallery_tab_controller.dart';
import 'screens/gallery/gallery_tab_opener.dart';
import 'screens/gallery/gallery_tabs_screen.dart';
import 'screens/gallery/home_gallery_body.dart';
import 'screens/pixiv/pixiv_login_screen.dart';
import 'services/cache/cache_manager.dart';
import 'services/cache/disk_cache.dart';
import 'services/cache/download_store.dart';
import 'services/cache/memory_cache.dart';
import 'services/favorites/favorites_store.dart';
import 'services/sources/favorites_source.dart';
import 'services/pixiv/pixiv_api_client.dart';
import 'services/pixiv/pixiv_web_client.dart';
import 'services/smb/smb_config_store.dart';
import 'services/sources/source_registry.dart';
import 'services/video/smb_proxy_server.dart';

final _log = Logger('App');

class ImageViewerApp extends StatelessWidget {
  const ImageViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const _AppRoot(),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> with WidgetsBindingObserver {
  final _webClient = PixivWebClient();
  final _smbConfigStore = SmbConfigStore();
  final _proxyServer = SmbProxyServer();
  late final SourceRegistry _registry;
  /// Open tabs live here so they outlive any gallery route (ADR 008).
  final _tabs = GalleryTabController();
  CacheManager? _cacheManager;
  FavoritesStore? _favoritesStore;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _registry = SourceRegistry(smbConfigStore: _smbConfigStore);
    _registry.onPixivLoginRequired = _handlePixivLogin;
    _initialize();
  }

  Future<void> _initialize() async {
    final l1 = MemoryCache(maxEntries: 10);
    final l2 = DiskCache();
    await l2.init();
    final l3 = DownloadStore();
    await l3.init();
    _cacheManager = CacheManager(l1: l1, l2: l2, l3: l3);
    _registry.cacheManager = _cacheManager;
    _registry.proxyServer = _proxyServer;

    final favStore = FavoritesStore();
    await favStore.init();
    _favoritesStore = favStore;
    // Starred works are a source like any other, so a tab can be opened on
    // them; it borrows each item's real source for the bytes.
    _registry.register(
      'fav:default',
      FavoritesSource(store: favStore, registry: _registry),
    );

    await _smbConfigStore.init();

    // The app always has somewhere to be, and that somewhere is a tab like any
    // other (ADR 008). Home used to be the route underneath the tabs; now it is
    // the first tab, so there is one way to be anywhere.
    if (_tabs.isEmpty) {
      _tabs.open(GalleryTab(homeSession(_cacheManager!)));
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  /// Lazy Pixiv login: called by SourceRegistry when Pixiv source is needed.
  ///
  /// Flow:
  /// 1. Initialize API WebView controller (no page load)
  /// 2. Push login screen (accounts.pixiv.net/login)
  ///    - Cookie valid → pixiv redirects to www.pixiv.net → pop immediately
  ///    - Cookie invalid → user logs in → www.pixiv.net reached → pop
  /// 3. Load pixiv.net in API WebView (with valid cookies now)
  /// 4. Return PixivApiClient
  Future<PixivApiClient?> _handlePixivLogin(BuildContext context) async {
    // Ensure API WebView controller is created
    await _webClient.initialize();

    // about:blank からの fetch は Cookie が付かない（Origin=null）ため
    // ログイン状態の事前確認はできない。常にログイン画面を push する。
    // Cookie 有効時は pixiv が www.pixiv.net に即リダイレクトするので
    // ログイン画面側でフォームを見せずにローディング表示で済ませる。
    _log.info('Pushing login screen');
    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PixivLoginScreen(
        webClient: _webClient,
        onLoginSuccess: ({String? userId}) {
          if (userId != null) {
            _webClient.userId = userId;
          }
          // Pop is handled by PixivLoginScreen itself using its own context
        },
      ),
    ));
    _log.info('Login screen returned: result=$result');

    if (result != true) return null;

    // API WebView はログイン画面側で loadPixivPage() 済み
    _log.info('API WebView ready, returning PixivApiClient');
    return PixivApiClient(webClient: _webClient);
  }

  /// Going away is when the cache index has to be on disk.
  ///
  /// It is written a few seconds after it changes rather than on every change,
  /// which is a window in which being killed would leave cached files that
  /// nothing knows about. Android kills backgrounded apps freely, so the way
  /// out is the one moment it must not be skipped.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    unawaited(_cacheManager?.l2.flushNow());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    _proxyServer.dispose();
    _registry.disposeAll();
    _webClient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return GalleryTabsScreen(
      controller: _tabs,
      opener: GalleryTabOpener(
        registry: _registry,
        cacheManager: _cacheManager!,
        favoritesStore: _favoritesStore!,
      ),
      smbConfigStore: _smbConfigStore,
      proxyServer: _proxyServer,
      cacheManager: _cacheManager!,
      favoritesStore: _favoritesStore!,
      registry: _registry,
    );
  }
}
