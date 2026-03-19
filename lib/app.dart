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
  final _smbConfigStore = SmbConfigStore();
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

    await _smbConfigStore.init();

    // API用WebViewの準備はバックグラウンドで進める（ログイン画面と並行）
    _webClient.initialize();

    setState(() {
      _isLoading = false;
    });
  }

  /// userId が取得できるまでバックグラウンドでリトライ。
  Future<void> _ensureUserId() async {
    try {
      final id = await _webClient.waitForUserId();
      print('[App] userId acquired: $id');
    } catch (e) {
      print('[App] Failed to acquire userId: $e');
    }
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
        onLoginSuccess: ({String? userId}) {
          if (userId != null) {
            _webClient.userId = userId;
          }
          if (!_isLoggedIn) {
            setState(() => _isLoggedIn = true);
            _webClient.initialize().then((_) => _ensureUserId());
          }
        },
      );
    }

    final apiClient = PixivApiClient(webClient: _webClient);
    final pixivSource = PixivSource(client: apiClient);

    return HomeScreen(
      pixivSource: pixivSource,
      cacheManager: _cacheManager!,
      favoritesStore: _favoritesStore!,
      smbConfigStore: _smbConfigStore,
    );
  }
}
