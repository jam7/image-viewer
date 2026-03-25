import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/image_source.dart';
import 'gallery_constants.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/smb_source.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../../widgets/thumbnail_result.dart';
import '../video/video_player_screen.dart';
import '../viewer/viewer_screen.dart';

final _log = Logger('SmbGallery');

/// SMBディレクトリブラウズ画面。
class SmbGalleryScreen extends StatefulWidget {
  final SmbSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;
  final SmbProxyServer proxyServer;
  final String initialPath;

  const SmbGalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    required this.proxyServer,
    this.initialPath = '/',
  });

  @override
  State<SmbGalleryScreen> createState() => _SmbGalleryScreenState();
}

class _SmbGalleryScreenState extends State<SmbGalleryScreen> {
  final List<ImageSource> _items = [];
  final Map<String, ThumbnailResult> _thumbnailData = {};
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  List<ImageSource> _imageFiles = []; // サムネイル読み込み対象（ディレクトリ除外）
  int _thumbnailLoadedCount = 0; // サムネイル読み込み済みの数
  bool _isLoading = false;
  bool _isLoadingThumbnails = false;
  String? _error;
  bool _isPopping = false;
  /// Incremented in _loadDirectory() to invalidate in-progress thumbnail loops.
  /// Thumbnail loading must capture this at start and abort if it changes.
  int _loadGeneration = 0;

  /// 画面に表示される行数から2画面分のアイテム数を計算
  int get _batchSize {
    if (!_scrollController.hasClients) return galleryCrossAxisCount * 6; // 初回のフォールバック
    final viewportHeight = _scrollController.position.viewportDimension;
    final itemHeight = (viewportHeight / galleryCrossAxisCount).ceilToDouble(); // 正方形グリッド
    final rowsPerScreen = (viewportHeight / (itemHeight + gallerySpacing)).ceil();
    return galleryCrossAxisCount * rowsPerScreen * 2; // 2画面分
  }

  @override
  void initState() {
    super.initState();
    _loadDirectory();
  }

  @override
  void deactivate() {
    _thumbnailData.clear();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (_imageFiles.isNotEmpty && _thumbnailData.isEmpty) {
      _reloadThumbnailsFromCache();
    }
  }

  Future<void> _reloadThumbnailsFromCache() async {
    final generation = _loadGeneration;
    for (final image in _imageFiles) {
      if (!mounted || generation != _loadGeneration) return;
      if (_thumbnailData.containsKey(image.id)) continue;
      try {
        final cached = await widget.cacheManager.get('thumb:${image.id}')
            ?? await widget.cacheManager.get('full:${image.id}');
        if (cached != null && mounted) {
          setState(() => _thumbnailData[image.id] = ThumbnailData(Uint8List.fromList(cached.data)));
        }
      } catch (e, st) {
        _log.warning('reloadThumbnail error', e, st);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }



  Future<void> _loadDirectory() async {
    _loadGeneration++;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    _items.clear();
    _thumbnailData.clear();
    _thumbnailLoadedCount = 0;

    try {
      final items = await widget.source.listImages(path: widget.initialPath);
      _imageFiles = items.where((i) =>
          i.metadata?['isDirectory'] != true &&
          i.metadata?['isVideo'] != true).toList();
      final videoFiles = items.where((i) => i.metadata?['isVideo'] == true).toList();
      setState(() {
        _items.addAll(items);
        _isLoading = false;
      });
      _loadNextBatch();
      _loadVideoThumbnails(videoFiles);
    } catch (e, st) {
      _log.warning('loadDirectory error', e, st);
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadNextBatch() async {
    if (_isLoadingThumbnails || _thumbnailLoadedCount >= _imageFiles.length) return;
    _isLoadingThumbnails = true;

    final end = (_thumbnailLoadedCount + _batchSize).clamp(0, _imageFiles.length);
    final batch = _imageFiles.sublist(_thumbnailLoadedCount, end);
    _thumbnailLoadedCount = end;

    await _loadThumbnails(batch);
    _isLoadingThumbnails = false;

    // 画面を埋めきれなければ追加読み込み
    _loadMoreIfNeeded();
  }

  void _loadMoreIfNeeded() {
    if (_thumbnailLoadedCount >= _imageFiles.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0) {
        _loadNextBatch();
      }
    });
  }

  Future<void> _loadThumbnails(Iterable<ImageSource> images) async {
    // 1行分（crossAxisCount枚）ずつ並列ダウンロード。
    // 全部同時に投げると帯域を奪い合い単体速度が落ちるため、
    // 行単位で区切って先に表示可能にする。
    final generation = _loadGeneration;
    final list = images.where((i) => !_thumbnailData.containsKey(i.id)).toList();
    for (int i = 0; i < list.length; i += galleryCrossAxisCount) {
      if (!mounted || generation != _loadGeneration) return;
      final end = (i + galleryCrossAxisCount).clamp(0, list.length);
      final row = list.sublist(i, end);
      await Future.wait(row.map(_loadOneThumbnail));
    }
  }

  Future<void> _loadOneThumbnail(ImageSource image) async {
    final thumbKey = 'thumb:${image.id}';
    try {
      final cached = await widget.cacheManager.get(thumbKey);
      if (cached != null) {
        if (mounted) {
          setState(() =>
              _thumbnailData[image.id] = ThumbnailData(Uint8List.fromList(cached.data)));
        }
      } else {
        final data = await widget.source.fetchThumbnail(image);
        widget.cacheManager.l1.put(thumbKey, data);
        await widget.cacheManager.l2.put(thumbKey, data);
        if (mounted) {
          setState(() => _thumbnailData[image.id] = ThumbnailData(data));
        }
      }
    } on ThumbnailNotSupportedException {
      _log.info('Thumbnail not supported: ${image.name}');
      if (mounted) {
        setState(() => _thumbnailData[image.id] = ThumbnailFailed(ThumbnailFailReason.notSupported));
      }
    } catch (e, st) {
      _log.warning('thumbnail error (${image.name})', e, st);
      if (mounted) {
        setState(() => _thumbnailData[image.id] = ThumbnailFailed(ThumbnailFailReason.timeout));
      }
    }
  }

  /// ビューアから戻った後、notSupported だったサムネイルを再取得する。
  /// PDF はビューア表示中に L2 にキャッシュされるため、戻った時に取得可能になる。
  void _retryUnsupportedThumbnails() {
    if (!mounted) return;
    final retryItems = _imageFiles.where((img) {
      final thumb = _thumbnailData[img.id];
      return thumb is ThumbnailFailed && thumb.reason == ThumbnailFailReason.notSupported;
    }).toList();
    if (retryItems.isEmpty) return;
    for (final img in retryItems) {
      _thumbnailData.remove(img.id);
    }
    _loadThumbnails(retryItems);
  }

  Future<void> _loadVideoThumbnails(List<ImageSource> videos) async {
    if (videos.isEmpty) return;

    // Reuse a single Player instance for all thumbnails
    final player = Player();
    VideoController(player);
    await player.setVolume(0);

    try {
      for (final video in videos) {
        if (!mounted) return;
        final thumbKey = 'thumb:${video.id}';
        try {
          // Check cache first
          final cached = await widget.cacheManager.get(thumbKey);
          if (cached != null) {
            if (mounted) {
              setState(() => _thumbnailData[video.id] = ThumbnailData(Uint8List.fromList(cached.data)));
            }
            continue;
          }

          // Capture first frame via proxy + media_kit
          final url = await widget.proxyServer.registerSession(widget.source, video.uri);
          final token = url.split('/').last;
          try {
            await player.open(Media(url));
            await player.stream.width
                .firstWhere((w) => w != null && w > 0)
                .timeout(const Duration(seconds: 15));
            await Future.delayed(const Duration(milliseconds: 300));
            await player.pause();
            final bytes = await player.screenshot(format: 'image/jpeg');
            if (bytes != null && mounted) {
              widget.cacheManager.l1.put(thumbKey, bytes);
              await widget.cacheManager.l2.put(thumbKey, bytes);
              setState(() => _thumbnailData[video.id] = ThumbnailData(bytes));
              _log.info('Video thumbnail: ${video.name} (${(bytes.length / 1024).toStringAsFixed(0)} KB)');
            }
          } finally {
            widget.proxyServer.invalidateToken(token);
          }
        } catch (e, st) {
          _log.warning('Video thumbnail failed: ${video.name}', e, st);
          if (mounted) {
            setState(() => _thumbnailData[video.id] = ThumbnailFailed(ThumbnailFailReason.timeout));
          }
        }
      }
    } finally {
      await player.dispose();
    }
  }

  void _onItemTap(ImageSource item) {
    if (item.metadata?['isDirectory'] == true) {
      final path = item.metadata?['path'] as String? ?? '/';
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SmbGalleryScreen(
          source: widget.source,
          cacheManager: widget.cacheManager,
          favoritesStore: widget.favoritesStore,
          registry: widget.registry,
          proxyServer: widget.proxyServer,
          initialPath: path,
        ),
      ));
    } else if (item.metadata?['isVideo'] == true) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          item: item,
          source: widget.source,
          proxyServer: widget.proxyServer,
        ),
      ));
    } else {
      // 画像/ZIP/PDFをフィルタしてビューアに渡す（動画を除外）
      final viewerItems = _items.where((i) =>
          i.metadata?['isDirectory'] != true &&
          i.metadata?['isVideo'] != true).toList();
      final index = viewerItems.indexWhere((i) => i.id == item.id);
      if (index >= 0) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ViewerScreen(
            items: viewerItems,
            initialIndex: index,
            registry: widget.registry,
            cacheManager: widget.cacheManager,
            favoritesStore: widget.favoritesStore,
          ),
        )).then((_) => _retryUnsupportedThumbnails());
      }
    }
  }



  void _scrollBy(double delta) {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      (_scrollController.offset + delta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_scrollController.hasClients) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(100);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-100);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.space) {
      _scrollBy(viewportHeight * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _scrollBy(-viewportHeight * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _scrollBy(-_scrollController.offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _scrollBy(_scrollController.position.maxScrollExtent - _scrollController.offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.escape) {
      _popOnce();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      _popOnce();
    }
  }

  /// Guard against multiple pop calls in the same frame
  /// (e.g. ESC key and mouse back button firing simultaneously).
  void _popOnce() {
    if (_isPopping) return;
    _isPopping = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: _buildScaffold(),
      ),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.initialPath,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(child: _buildGrid()),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_items.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && !_isLoading) {
      return const Center(child: Text('ファイルが見つかりませんでした'));
    }

    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(4),
        gridDelegate: galleryGridDelegate,
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          final isDir = item.metadata?['isDirectory'] == true;
          final thumb = _thumbnailData[item.id];

          // Trigger next batch when an untried item becomes visible.
          if (!isDir && thumb == null && !_isLoadingThumbnails) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_isLoadingThumbnails) _loadNextBatch();
            });
          }

          final isVideo = item.metadata?['isVideo'] == true;

          final videoThumb = isVideo ? _thumbnailData[item.id] : null;

          return GestureDetector(
            onTap: () => _onItemTap(item),
            child: isDir
                ? _buildIconTile(item.name, Icons.folder, Colors.amber)
                : isVideo
                ? (videoThumb is ThumbnailData
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(videoThumb.data, fit: BoxFit.cover),
                          const Center(
                            child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 48),
                          ),
                        ],
                      )
                    : _buildIconTile(item.name, Icons.play_circle_outline, Colors.deepPurple))
                : switch (thumb) {
                    ThumbnailData(data: final d) =>
                      Image.memory(d, fit: BoxFit.cover),
                    ThumbnailFailed(reason: ThumbnailFailReason.notSupported) =>
                      _buildIconTile(item.name, Icons.archive, Colors.blueGrey),
                    ThumbnailFailed(reason: ThumbnailFailReason.timeout) =>
                      _buildIconTile(item.name, Icons.broken_image, Colors.red[300]!),
                    null => Container(
                        color: Colors.grey[300],
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  },
          );
        },
      ),
    );
  }

  Widget _buildIconTile(String name, IconData icon, Color color) {
    return Container(
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 4),
          Text(
            name,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

