import 'package:flutter/material.dart';

import 'screens/gallery/gallery_screen.dart';
import 'screens/pixiv/pixiv_login_screen.dart';
import 'services/cache/cache_manager.dart';
import 'services/cache/disk_cache.dart';
import 'services/cache/download_store.dart';
import 'services/cache/memory_cache.dart';
import 'services/favorites/favorites_store.dart';
import 'services/pixiv/pixiv_api_client.dart';
import 'services/pixiv/pixiv_web_client.dart';
import 'services/sources/pixiv_source.dart';

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

/// ログイン状態に応じてログイン画面 or ギャラリーを表示。
class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  final _webClient = PixivWebClient();
  CacheManager? _cacheManager;
  FavoritesStore? _favoritesStore;
  bool _isLoggedIn = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
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

    await _webClient.initialize();
    final loggedIn = await _webClient.checkLoginStatus();

    setState(() {
      _isLoggedIn = loggedIn;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
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

    if (!_isLoggedIn) {
      return PixivLoginScreen(
        webClient: _webClient,
        onLoginSuccess: () => setState(() => _isLoggedIn = true),
      );
    }

    final apiClient = PixivApiClient(webClient: _webClient);
    final pixivSource = PixivSource(client: apiClient);

    return GalleryScreen(
      source: pixivSource,
      cacheManager: _cacheManager!,
      favoritesStore: _favoritesStore!,
    );
  }
}
