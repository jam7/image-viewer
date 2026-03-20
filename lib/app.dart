import 'package:flutter/material.dart';

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

    final favStore = FavoritesStore();
    await favStore.init();
    _favoritesStore = favStore;

    await _smbConfigStore.init();

    // Pixiv WebView is initialized lazily when user first accesses Pixiv
    // (via _handlePixivLogin). No need to start it here.

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Lazy Pixiv login: called by SourceRegistry when Pixiv source is needed.
  /// Returns PixivApiClient if login succeeds, null if cancelled.
  Future<PixivApiClient?> _handlePixivLogin(BuildContext context) async {
    // Initialize API WebView on first Pixiv access
    await _webClient.initialize();

    // Check if already logged in (cookies still valid)
    final loggedIn = await _webClient.checkLoginStatus();
    if (loggedIn) {
      return PixivApiClient(webClient: _webClient);
    }

    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PixivLoginScreen(
        onLoginSuccess: ({String? userId}) {
          if (userId != null) {
            _webClient.userId = userId;
          }
          // userId is set by PixivLoginScreen._extractUserIdAsync
          // and verified by checkLoginStatus after login completes.
          // No need to call waitForUserId here (it would run fetchJson
          // in the background, interfering with gallery API calls).

          // Delay pop to avoid calling during navigation lock
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context).pop(true);
          });
        },
      ),
    ));

    if (result != true) return null;

    // Reload API WebView to pick up cookies from login WebView
    await _webClient.initialize();
    await _webClient.reload();
    return PixivApiClient(webClient: _webClient);
  }

  @override
  void dispose() {
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
    );
  }
}
