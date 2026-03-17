import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/image_source.dart';
import 'gallery_constants.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/smb_source.dart';
import '../viewer/viewer_screen.dart';

/// SMBディレクトリブラウズ画面。
class SmbGalleryScreen extends StatefulWidget {
  final SmbSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final String initialPath;

  const SmbGalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
    this.initialPath = '/',
  });

  @override
  State<SmbGalleryScreen> createState() => _SmbGalleryScreenState();
}

class _SmbGalleryScreenState extends State<SmbGalleryScreen> {
  final List<ImageSource> _items = [];
  final Map<String, Uint8List> _thumbnailData = {};
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  List<ImageSource> _imageFiles = []; // サムネイル読み込み対象（ディレクトリ除外）
  int _thumbnailLoadedCount = 0; // サムネイル読み込み済みの数
  bool _isLoading = false;
  bool _isLoadingThumbnails = false;
  String? _error;

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
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }



  Future<void> _loadDirectory() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    _items.clear();
    _thumbnailData.clear();
    _thumbnailLoadedCount = 0;

    try {
      final items = await widget.source.listImages(path: widget.initialPath);
      _imageFiles = items.where((i) => i.metadata?['isDirectory'] != true).toList();
      setState(() {
        _items.addAll(items);
        _isLoading = false;
      });
      _loadNextBatch();
    } catch (e, st) {
      print('[SmbGallery] loadDirectory error: $e\n$st');
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
    final queue = images.where((i) => !_thumbnailData.containsKey(i.id)).toList();
    const concurrency = 3;
    var index = 0;

    Future<void> worker() async {
      while (index < queue.length) {
        final image = queue[index++];
        await _loadOneThumbnail(image);
      }
    }

    await Future.wait(List.generate(
      concurrency.clamp(0, queue.length),
      (_) => worker(),
    ));
  }

  Future<void> _loadOneThumbnail(ImageSource image) async {
    final thumbKey = 'thumb:${image.id}';
    final fullKey = 'full:${image.id}';
    try {
      // thumb: → full: の順でキャッシュを探す
      final cached = await widget.cacheManager.get(thumbKey)
          ?? await widget.cacheManager.get(fullKey);
      if (cached != null) {
        if (mounted) {
          setState(() =>
              _thumbnailData[image.id] = Uint8List.fromList(cached.data));
        }
      } else {
        // まずダウンロードして、フォールバックしたか判定してからキャッシュ
        final data = await widget.source.fetchThumbnail(image);
        final saveKey = widget.source.lastThumbnailWasFullImage
            ? fullKey : thumbKey;
        widget.cacheManager.l1.put(saveKey, data);
        await widget.cacheManager.l2.put(saveKey, data);
        if (mounted) {
          setState(() => _thumbnailData[image.id] = data);
        }
      }
    } catch (e, st) {
      print('[SmbGallery] thumbnail error: $e\n$st');
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
          initialPath: path,
        ),
      ));
    } else {
      // 画像のみフィルタしてビューアに渡す
      final imageItems =
          _items.where((i) => i.metadata?['isDirectory'] != true).toList();
      final index = imageItems.indexWhere((i) => i.id == item.id);
      if (index >= 0) {
        // ディレクトリ内の全画像をページとして渡す
        // クリックした画像を先頭に、以降を順番に並べる
        final reordered = [
          ...imageItems.sublist(index),
          ...imageItems.sublist(0, index),
        ];
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ViewerScreen(
            initialImage: imageItems[index],
            source: widget.source,
            resolvePages: (_) async => reordered,
            cacheManager: widget.cacheManager,
            favoritesStore: widget.favoritesStore,
          ),
        ));
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
    if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      Navigator.of(context).pop();
    }
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

    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(4),
      gridDelegate: galleryGridDelegate,
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        final isDir = item.metadata?['isDirectory'] == true;
        final thumbnail = _thumbnailData[item.id];

        // サムネイル未読み込みの画像が表示されようとしたら次バッチ開始
        if (!isDir && thumbnail == null && !_isLoadingThumbnails) {
          _loadNextBatch();
        }

        return GestureDetector(
          onTap: () => _onItemTap(item),
          child: isDir
              ? Container(
                  color: Colors.grey[200],
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.folder, size: 48, color: Colors.amber),
                      const SizedBox(height: 4),
                      Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                )
              : thumbnail != null
                  ? Image.memory(thumbnail, fit: BoxFit.cover)
                  : Container(
                      color: Colors.grey[300],
                      child: const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
        );
      },
    );
  }
}

