import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../models/server_config.dart';
import '../cache/cache_manager.dart';
import '../pixiv/pixiv_api_client.dart';
import '../smb/smb_config_store.dart';
import '../video/smb_proxy_server.dart';
import 'image_source_provider.dart';
import 'pixiv_source.dart';
import 'smb_source.dart';

final _log = Logger('SourceRegistry');

/// Resolves sourceKey to ImageSourceProvider.
///
/// sourceKey format: "type:id" (e.g. "pixiv:default", "smb:1700000000000")
///
/// Handles lazy initialization: Pixiv requires login, SMB requires
/// password retrieval and connection establishment.
///
/// For Pixiv, each resolve() returns a new PixivSource instance so that
/// each screen has its own pagination state (like a file descriptor).
/// The underlying PixivApiClient (authentication/WebView) is shared.
class SourceRegistry {
  /// Sources handed to us ready to use — the favorites list at startup, an SMB
  /// server once connected. Not only SMB, despite where it began.
  final Map<String, ImageSourceProvider> _registered = {};
  final SmbConfigStore _smbConfigStore;
  CacheManager? cacheManager;
  /// Local HTTP proxy for SMB video (playback + thumbnail capture). Injected by
  /// _AppRoot; passed to each SmbSource so it can capture video thumbnails.
  SmbProxyServer? proxyServer;

  PixivApiClient? _pixivApiClient;
  bool _pixivLoginVerified = false;
  /// Guards against concurrent _resolvePixiv calls (e.g. FavoritesTab and
  /// HomeScreen both calling resolve at the same time).
  Future<ImageSourceProvider?>? _pixivResolveFuture;

  // Callback for lazy Pixiv login
  Future<PixivApiClient?> Function(BuildContext context)? onPixivLoginRequired;

  SourceRegistry({required SmbConfigStore smbConfigStore, this.cacheManager})
      : _smbConfigStore = smbConfigStore;

  /// Register a ready-made source under [key], so [resolve] can hand it back
  /// without knowing how to build it.
  void register(String key, ImageSourceProvider provider) {
    _registered[key] = provider;
  }

  /// Set the Pixiv API client (shared across all PixivSource instances).
  void setPixivApiClient(PixivApiClient client) {
    _pixivApiClient = client;
  }

  bool get isPixivAvailable => _pixivApiClient != null;

  /// Resolve a sourceKey to a provider. May trigger login or connection.
  /// Returns null if the source cannot be resolved (e.g. login cancelled).
  ///
  /// For Pixiv, a new PixivSource is returned each time so each caller
  /// gets independent pagination state.
  Future<ImageSourceProvider?> resolve(String sourceKey, BuildContext context) async {
    _log.info('resolve: $sourceKey');
    // Already registered — the favorites list, or a server connected earlier.
    // Checked before the scheme switch, which only knows how to build the two
    // sources that need building.
    final registered = _registered[sourceKey];
    if (registered != null) return registered;

    // Parse key
    final parts = sourceKey.split(':');
    if (parts.length < 2) {
      _log.info('resolve: invalid key format');
      return null;
    }
    final type = parts[0];
    final id = parts.sublist(1).join(':');

    switch (type) {
      case 'pixiv':
        return _resolvePixiv(context);

      case 'smb':
        return _resolveSmb(id);

      default:
        _log.info('resolve: unknown type "$type"');
        return null;
    }
  }

  Future<ImageSourceProvider?> _resolvePixiv(BuildContext context) {
    // Already logged in and verified — no need for serialization
    if (_pixivApiClient != null && _pixivLoginVerified) {
      _log.info('_resolvePixiv: already verified, returning new PixivSource');
      return Future.value(PixivSource(client: _pixivApiClient!));
    }
    // Serialize login attempts to prevent double login screen
    return _pixivResolveFuture ??= _doResolvePixiv(context).whenComplete(() {
      _pixivResolveFuture = null;
    });
  }

  Future<ImageSourceProvider?> _doResolvePixiv(BuildContext context) async {
    if (onPixivLoginRequired != null) {
      _log.info('_resolvePixiv: calling onPixivLoginRequired');
      final client = await onPixivLoginRequired!(context);
      _log.info('_resolvePixiv: login returned client=${client != null}');
      if (client != null) {
        _pixivApiClient = client;
        _pixivLoginVerified = true;
        return PixivSource(client: client);
      }
    }
    _log.info('_resolvePixiv: failed to resolve');
    return null;
  }

  Future<ImageSourceProvider?> _resolveSmb(String configId) async {
    final key = 'smb:$configId';

    final configs = _smbConfigStore.listAll();
    final config = configs.where((c) => c.id == configId).firstOrNull;
    if (config == null) return null;

    final password = await _smbConfigStore.getPassword(configId);
    if (password == null) return null;

    final source = SmbSource(
      config: config,
      password: password,
      cacheManager: cacheManager,
      proxyServer: proxyServer,
    );
    _registered[key] = source;
    return source;
  }

  /// The provider for [sourceKey] if it is already available — no login
  /// prompt, no connection to establish. Null when getting it would need a
  /// BuildContext, which a background fetch has no business demanding.
  ImageSourceProvider? peek(String sourceKey) {
    final registered = _registered[sourceKey];
    if (registered != null) return registered;
    if (sourceKey.startsWith('pixiv:')) return createPixivSource();
    return null;
  }

  /// Every source currently available, for operations that span all of them.
  Iterable<ImageSourceProvider> get connectedSources => _registered.values;

  /// Get sourceKey for a server config.
  static String keyForSmb(ServerConfig config) => 'smb:${config.id}';
  static const String keyForPixiv = 'pixiv:default';

  /// Create a new PixivSource with the shared API client.
  /// Returns null if not logged in.
  PixivSource? createPixivSource() {
    if (_pixivApiClient == null) return null;
    return PixivSource(client: _pixivApiClient!);
  }

  /// Dispose all sources.
  Future<void> disposeAll() async {
    for (final source in _registered.values) {
      try {
        await source.dispose();
      } catch (e, st) {
        _log.warning('dispose error', e, st);
      }
    }
    _registered.clear();
    _pixivApiClient?.dispose();
    _pixivApiClient = null;
    _pixivLoginVerified = false;
  }
}
