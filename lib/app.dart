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
import 'services/sources/pixiv_source.dart';
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
  PixivSource? _pixivSource;
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

    // Try background Pixiv init (may succeed if cookies are still valid)
    _webClient.initialize();

    setState(() {
      _isLoading = false;
    });
  }

  /// Lazy Pixiv login: called when user taps Pixiv or opens a Pixiv favorite.
  Future<PixivSource?> _handlePixivLogin(BuildContext context) async {
    if (_pixivSource != null) return _pixivSource;

    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PixivLoginScreen(
        onLoginSuccess: ({String? userId}) {
          if (userId != null) {
            _webClient.userId = userId;
          }
          _webClient.initialize().then((_) async {
            try {
              final id = await _webClient.waitForUserId();
              print('[App] userId acquired: $id');
            } catch (e) {
              print('[App] Failed to acquire userId: $e');
            }
          });
          Navigator.of(context).pop(true);
        },
      ),
    ));

    if (result != true) return null;

    final apiClient = PixivApiClient(webClient: _webClient);
    _pixivSource = PixivSource(client: apiClient);
    _registry.setPixivSource(_pixivSource!);
    return _pixivSource;
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

    // If Pixiv source not yet created, create a placeholder that will be
    // replaced after login. Gallery won't load data until login succeeds.
    final pixivSource = _pixivSource ??
        PixivSource(client: PixivApiClient(webClient: _webClient));

    return HomeScreen(
      pixivSource: pixivSource,
      cacheManager: _cacheManager!,
      favoritesStore: _favoritesStore!,
      smbConfigStore: _smbConfigStore,
      registry: _registry,
    );
  }
}
