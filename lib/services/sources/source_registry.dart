import 'package:flutter/material.dart';

import '../../models/server_config.dart';
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
class SourceRegistry {
  final Map<String, ImageSourceProvider> _sources = {};
  final SmbConfigStore _smbConfigStore;

  // Pixiv setup: set externally after login
  PixivSource? _pixivSource;

  // Callback for lazy Pixiv login
  Future<PixivSource?> Function(BuildContext context)? onPixivLoginRequired;

  SourceRegistry({required SmbConfigStore smbConfigStore})
      : _smbConfigStore = smbConfigStore;

  /// Register a source for a given key.
  void register(String key, ImageSourceProvider provider) {
    _sources[key] = provider;
  }

  /// Set the Pixiv source (after login).
  void setPixivSource(PixivSource source) {
    _pixivSource = source;
    _sources['pixiv:default'] = source;
  }

  bool get isPixivAvailable => _pixivSource != null;

  /// Resolve a sourceKey to a provider. May trigger login or connection.
  /// Returns null if the source cannot be resolved (e.g. login cancelled).
  Future<ImageSourceProvider?> resolve(String sourceKey, BuildContext context) async {
    // Already registered
    if (_sources.containsKey(sourceKey)) {
      return _sources[sourceKey];
    }

    // Parse key
    final parts = sourceKey.split(':');
    if (parts.length < 2) return null;
    final type = parts[0];
    final id = parts.sublist(1).join(':');

    switch (type) {
      case 'pixiv':
        if (_pixivSource != null) {
          _sources[sourceKey] = _pixivSource!;
          return _pixivSource;
        }
        // Lazy login
        if (onPixivLoginRequired != null) {
          final source = await onPixivLoginRequired!(context);
          if (source != null) {
            _pixivSource = source;
            _sources[sourceKey] = source;
          }
          return source;
        }
        return null;

      case 'smb':
        return _resolveSmb(id);

      default:
        return null;
    }
  }

  Future<ImageSourceProvider?> _resolveSmb(String configId) async {
    final configs = _smbConfigStore.listAll();
    final config = configs.where((c) => c.id == configId).firstOrNull;
    if (config == null) return null;

    final password = await _smbConfigStore.getPassword(configId);
    if (password == null) return null;

    final source = SmbSource(config: config, password: password);
    final key = 'smb:$configId';
    _sources[key] = source;
    return source;
  }

  /// Get sourceKey for a server config.
  static String keyForSmb(ServerConfig config) => 'smb:${config.id}';
  static const String keyForPixiv = 'pixiv:default';

  /// Dispose all sources.
  Future<void> disposeAll() async {
    for (final source in _sources.values) {
      try {
        await source.dispose();
      } catch (e, st) {
        print('[SourceRegistry] dispose error: $e\n$st');
      }
    }
    _sources.clear();
    _pixivSource = null;
  }
}
