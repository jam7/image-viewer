import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'screens/home/home_screen.dart';
import 'screens/pixiv/pixiv_login_screen.dart';
import 'services/cache/cache_manager.dart';
import 'services/cache/disk_cache.dart';
import 'services/cache/download_store.dart';
import 'services/cache/memory_cache.dart';
import 'services/favorites/favorites_store.dart';
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

class _AppRootState extends State<_AppRoot> {
  final _webClient = PixivWebClient();
  final _smbConfigStore = SmbConfigStore();
  final _proxyServer = SmbProxyServer();
  late final SourceRegistry _registry;
  CacheManager? _cacheManager;
  FavoritesStore? _favoritesStore;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
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

    final favStore = FavoritesStore();
    await favStore.init();
    _favoritesStore = favStore;

    await _smbConfigStore.init();

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

  @override
  void dispose() {
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

    return HomeScreen(
      cacheManager: _cacheManager!,
      favoritesStore: _favoritesStore!,
      smbConfigStore: _smbConfigStore,
      registry: _registry,
      proxyServer: _proxyServer,
    );
  }
}
