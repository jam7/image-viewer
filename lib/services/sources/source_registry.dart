import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../pixiv/pixiv_api_client.dart';
import '../smb/smb_config_store.dart';
import 'image_source_provider.dart';
import 'pixiv_source.dart';
import 'smb_source.dart';

/// Resolves sourceKey to ImageSourceProvider.
///
/// sourceKey format: "type:id" (e.g. "pixiv:default", "smb:1773662275240")
///
/// Handles lazy initialization: Pixiv requires login, SMB requires
/// password retrieval and connection establishment.
///
/// For Pixiv, each resolve() returns a new PixivSource instance so that
/// each screen has its own pagination state (like a file descriptor).
/// The underlying PixivApiClient (authentication/WebView) is shared.
class SourceRegistry {
  final Map<String, ImageSourceProvider> _smbSources = {};
  final SmbConfigStore _smbConfigStore;

  PixivApiClient? _pixivApiClient;
  bool _pixivLoginVerified = false;

  // Callback for lazy Pixiv login
  Future<PixivApiClient?> Function(BuildContext context)? onPixivLoginRequired;

  SourceRegistry({required SmbConfigStore smbConfigStore})
      : _smbConfigStore = smbConfigStore;

  /// Register an SMB source for a given key.
  void register(String key, ImageSourceProvider provider) {
    _smbSources[key] = provider;
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
    // Parse key
    final parts = sourceKey.split(':');
    if (parts.length < 2) return null;
    final type = parts[0];
    final id = parts.sublist(1).join(':');

    switch (type) {
      case 'pixiv':
        return _resolvePixiv(context);

      case 'smb':
        return _resolveSmb(id);

      default:
        return null;
    }
  }

  Future<ImageSourceProvider?> _resolvePixiv(BuildContext context) async {
    // Already logged in and verified
    if (_pixivApiClient != null && _pixivLoginVerified) {
      return PixivSource(client: _pixivApiClient!);
    }
    // Trigger login (checks cookies, shows login screen if needed)
    if (onPixivLoginRequired != null) {
      final client = await onPixivLoginRequired!(context);
      if (client != null) {
        _pixivApiClient = client;
        _pixivLoginVerified = true;
        return PixivSource(client: client);
      }
    }
    return null;
  }

  Future<ImageSourceProvider?> _resolveSmb(String configId) async {
    final key = 'smb:$configId';
    if (_smbSources.containsKey(key)) {
      return _smbSources[key];
    }

    final configs = _smbConfigStore.listAll();
    final config = configs.where((c) => c.id == configId).firstOrNull;
    if (config == null) return null;

    final password = await _smbConfigStore.getPassword(configId);
    if (password == null) return null;

    final source = SmbSource(config: config, password: password);
    _smbSources[key] = source;
    return source;
  }

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
    for (final source in _smbSources.values) {
      try {
        await source.dispose();
      } catch (e, st) {
        print('[SourceRegistry] dispose error: $e\n$st');
      }
    }
    _smbSources.clear();
    _pixivApiClient = null;
    _pixivLoginVerified = false;
  }
}
