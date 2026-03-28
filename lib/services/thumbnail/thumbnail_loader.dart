import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../widgets/thumbnail_result.dart';
import '../cache/cache_manager.dart';
import '../sources/smb_source.dart';
import '../video/smb_proxy_server.dart';
import '../video/video_thumbnail_service.dart';

final _log = Logger('ThumbnailLoader');

/// Callback for each thumbnail result (success or failure).
typedef ThumbnailResultCallback = void Function(String id, ThumbnailResult result);

/// Manages batch loading of thumbnails with cancellation and retry.
///
/// Images are loaded in parallel rows for bandwidth efficiency.
/// Videos are loaded sequentially at the end of each batch to avoid
/// SMB connection contention.
///
/// Call [cancel] before video playback to free SMB connections,
/// then [retryInterrupted] on return.
class ThumbnailLoader {
  final SmbSource source;
  final CacheManager cacheManager;
  final SmbProxyServer proxyServer;
  final ThumbnailResultCallback onResult;
  final int batchSize;
  final int parallelCount;

  /// Items eligible for thumbnail loading (directories excluded).
  List<ImageSource> _items = [];
  /// How far into [_items] we have dispatched batches.
  int _loadedCount = 0;
  /// Set of item IDs that have received a result (success or failure).
  final Set<String> _resultIds = {};
  /// Incremented to cancel in-progress batch loops.
  int _generation = 0;
  bool _isLoading = false;
  VideoThumbnailService? _videoThumbService;

  ThumbnailLoader({
    required this.source,
    required this.cacheManager,
    required this.proxyServer,
    required this.onResult,
    required this.batchSize,
    required this.parallelCount,
  });

  bool get isLoading => _isLoading;
  int get loadedCount => _loadedCount;
  int get itemCount => _items.length;

  /// Set the items to load thumbnails for. Resets all state.
  void setItems(List<ImageSource> items) {
    _generation++;
    _items = items;
    _loadedCount = 0;
    _resultIds.clear();
  }

  /// Whether [itemIndex] is beyond the current batch (used by build trigger).
  bool needsBatch(int itemIndex) {
    return itemIndex >= _loadedCount && !_isLoading;
  }

  /// Start the next batch of thumbnails.
  Future<void> loadNextBatch() async {
    if (_isLoading || _loadedCount >= _items.length) return;
    _isLoading = true;

    final end = (_loadedCount + batchSize).clamp(0, _items.length);
    final batch = _items.sublist(_loadedCount, end);
    _loadedCount = end;

    await _loadThumbnails(batch);
    _isLoading = false;
  }

  /// Cancel in-progress loading (e.g. before video playback).
  void cancel() {
    _generation++;
    _isLoading = false;
    _videoThumbService?.dispose();
    _videoThumbService = null;
  }

  /// Retry items in the already-dispatched range that lack results.
  Future<void> retryInterrupted() async {
    final retryItems = _items.sublist(0, _loadedCount).where((img) {
      return !_resultIds.contains(img.id);
    }).toList();
    if (retryItems.isEmpty) return;
    _log.info('Retrying ${retryItems.length} interrupted thumbnails');
    _isLoading = true;
    await _loadThumbnails(retryItems);
    _isLoading = false;
  }

  /// Retry items that failed with [ThumbnailFailReason.notSupported].
  /// Called after viewer/player return when cached data may be available.
  void retryUnsupported(bool Function(String id) isUnsupported) {
    final retryItems = _items.where((img) => isUnsupported(img.id)).toList();
    if (retryItems.isEmpty) return;
    _loadThumbnails(retryItems);
  }

  /// Whether all items have been dispatched.
  bool get allDispatched => _loadedCount >= _items.length;

  Future<void> dispose() async {
    _generation++;
    _videoThumbService?.dispose();
    _videoThumbService = null;
  }

  // -- Private --

  Future<void> _loadThumbnails(Iterable<ImageSource> images) async {
    final generation = _generation;
    final batchCount = images.length;
    final list = images.where((i) => !_resultIds.contains(i.id)).toList();
    final skipped = batchCount - list.length;
    final imageItems = list.where((i) => i.metadata?['isVideo'] != true).toList();
    final videoItems = list.where((i) => i.metadata?['isVideo'] == true).toList();
    _log.info('Batch: ${imageItems.length} images + ${videoItems.length} videos ($skipped already loaded)');

    for (int i = 0; i < imageItems.length; i += parallelCount) {
      if (generation != _generation) return;
      final end = (i + parallelCount).clamp(0, imageItems.length);
      final row = imageItems.sublist(i, end);
      await Future.wait(row.map(_loadOne));
    }

    for (final video in videoItems) {
      if (generation != _generation) return;
      await _loadOne(video);
    }
  }

  Future<void> _loadOne(ImageSource image) async {
    final thumbKey = 'thumb:${image.id}';
    try {
      final cached = await cacheManager.get(thumbKey);
      if (cached != null) {
        _emitResult(image.id, ThumbnailData(Uint8List.fromList(cached.data)));
      } else if (image.metadata?['isVideo'] == true) {
        await _loadVideoThumbnail(image, thumbKey);
      } else {
        final data = await source.fetchThumbnail(image);
        cacheManager.l1.put(thumbKey, data);
        await cacheManager.l2.put(thumbKey, data);
        _emitResult(image.id, ThumbnailData(data));
      }
    } on ThumbnailNotSupportedException {
      _log.info('Thumbnail not supported: ${image.name}');
      _emitResult(image.id, ThumbnailFailed(ThumbnailFailReason.notSupported));
    } catch (e, st) {
      _log.warning('thumbnail error (${image.name})', e, st);
      _emitResult(image.id, ThumbnailFailed(ThumbnailFailReason.timeout));
    }
  }

  Future<void> _loadVideoThumbnail(ImageSource image, String thumbKey) async {
    final url = await proxyServer.registerSession(source, image.uri);
    final token = url.split('/').last;
    try {
      _videoThumbService ??= VideoThumbnailService();
      final bytes = await _videoThumbService!.capture(url);
      if (bytes != null) {
        final resized = await source.resizeToThumbnail(bytes);
        cacheManager.l1.put(thumbKey, resized);
        await cacheManager.l2.put(thumbKey, resized);
        _emitResult(image.id, ThumbnailData(resized));
        _log.info('Video thumbnail: ${image.name} (${(bytes.length / 1024).toStringAsFixed(0)} KB → ${(resized.length / 1024).toStringAsFixed(0)} KB)');
      }
    } finally {
      proxyServer.invalidateToken(token);
    }
  }

  void _emitResult(String id, ThumbnailResult result) {
    _resultIds.add(id);
    onResult(id, result);
  }
}
