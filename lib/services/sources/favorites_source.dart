import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../cache/cache_metadata.dart';
import '../favorites/favorites_store.dart';
import 'image_source_provider.dart';
import 'source_registry.dart';

final _log = Logger('FavoritesSource');

/// The starred works from every source as one list (ADR 007 R1).
///
/// Owns no content of its own. The entries live in [FavoritesStore], and each
/// item's bytes still belong to wherever it came from, so everything but the
/// listing is handed to that item's own provider.
///
/// Delegation is best-effort: a favourite from a server that has not been
/// connected this run has no provider to ask, and connecting one from a
/// background thumbnail fetch could put a login screen up unprompted. Those
/// items fall back to whatever is cached, which is what a thumbnail failure
/// means to the loader.
class FavoritesSource implements ImageSourceProvider {
  final FavoritesStore store;
  final SourceRegistry registry;

  FavoritesSource({required this.store, required this.registry});

  @override
  Future<List<ImageSource>> listImages({String? path}) async =>
      store.listAll().map(_toImageSource).toList();

  /// Keeps each entry's own type and source key, so an SMB favourite stays an
  /// SMB item — the item is only visiting this list.
  ImageSource _toImageSource(FavoriteEntry entry) {
    final typeName = entry.sourceInfo['type'] as String?;
    return ImageSource(
      id: entry.imageId,
      name: entry.name,
      uri: entry.uri,
      type: ImageSourceType.values.firstWhere(
        (t) => t.name == typeName,
        orElse: () => ImageSourceType.pixiv,
      ),
      sourceKey: entry.sourceKey,
      metadata: {...entry.sourceInfo, 'thumbnailUrl': entry.thumbnailUrl},
    );
  }

  /// The provider that owns [source], if it can be had without a prompt.
  ImageSourceProvider? _ownerOf(ImageSource source) {
    final key = source.sourceKey;
    if (key == null) return null;
    return registry.peek(key);
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) {
    final owner = _ownerOf(source);
    if (owner == null) {
      throw ThumbnailNotSupportedException(
          'no connected source for ${source.name} (${source.sourceKey})');
    }
    return owner.fetchThumbnail(source);
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) {
    final owner = _ownerOf(source);
    if (owner == null) {
      throw StateError('no connected source for ${source.sourceKey}');
    }
    return owner.fetchFullImage(source, onProgress: onProgress);
  }

  @override
  Future<List<ImageSource>> resolvePages(ImageSource source) async {
    final owner = _ownerOf(source);
    return owner == null ? [source] : owner.resolvePages(source);
  }

  @override
  Future<({Stream<Uint8List> stream, int fileSize, Future<void> Function() close})>
      openReadStream(ImageSource source) {
    final owner = _ownerOf(source);
    if (owner == null) {
      throw StateError('no connected source for ${source.sourceKey}');
    }
    return owner.openReadStream(source);
  }

  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async =>
      PageResult(items: await listImages());

  /// Cancelling reaches every source that might be mid-fetch for this list —
  /// but not this one, which is registered among them and would otherwise call
  /// itself forever.
  @override
  void cancelThumbnailWork() {
    for (final provider in registry.connectedSources) {
      if (identical(provider, this)) continue;
      provider.cancelThumbnailWork();
    }
  }

  /// Nothing to release: every provider here is owned by the registry.
  @override
  Future<void> dispose() async {
    _log.info('dispose (no owned resources)');
  }
}
