import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/cache/cache_metadata.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';

/// 画像ビューア画面。
/// - マウスホイール / 矢印キー / Page Up・Down: ページ送り
/// - Ctrl + マウスホイール: 拡大縮小（画像中心起点）
class ViewerScreen extends StatefulWidget {
  final ImageSource initialImage;
  final PixivSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;

  const ViewerScreen({
    super.key,
    required this.initialImage,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
  });

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  List<ImageSource>? _pages;
  int _currentIndex = 0;
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  final Map<String, Uint8List> _fullImages = {};
  final Map<String, CacheSource> _cacheSources = {};
  final Map<String, bool> _loadingStates = {};
  bool _showOverlay = true;
  bool _isResolvingPages = true;
  String? _error;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _resolvePages();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _resolvePages() async {
    try {
      final pages = await widget.source.resolvePages(widget.initialImage);
      if (mounted) {
        setState(() {
          _pages = pages;
          _isResolvingPages = false;
        });
        _preloadAround(0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isResolvingPages = false;
        });
      }
    }
  }

  void _preloadAround(int index) {
    final pages = _pages;
    if (pages == null) return;
    for (var i = index - 1; i <= index + 2; i++) {
      if (i >= 0 && i < pages.length) {
        _loadFullImage(i);
      }
    }
  }

  Future<void> _loadFullImage(int index) async {
    final pages = _pages!;
    final image = pages[index];
    if (_fullImages.containsKey(image.id) ||
        _loadingStates[image.id] == true) {
      return;
    }

    _loadingStates[image.id] = true;
    final key = 'full:${image.id}';

    try {
      final cached = await widget.cacheManager.get(key);
      if (cached != null) {
        if (mounted) {
          setState(() {
            _fullImages[image.id] = Uint8List.fromList(cached.data);
            _cacheSources[image.id] = cached.source;
          });
        }
      } else {
        final result = await widget.cacheManager.fetchAndCache(
          key,
          () => widget.source.fetchFullImage(image),
        );
        if (mounted) {
          setState(() {
            _fullImages[image.id] = Uint8List.fromList(result.data);
            _cacheSources[image.id] = result.source;
          });
        }
      }
    } catch (_) {
      // ロード失敗
    } finally {
      _loadingStates[image.id] = false;
    }
  }

  void _goToPage(int index) {
    final pages = _pages;
    if (pages == null) return;
    if (index < 0 || index >= pages.length) return;
    setState(() {
      _currentIndex = index;
      _scale = 1.0;
      _offset = Offset.zero;
    });
    _preloadAround(index);
  }

  void _nextPage() => _goToPage(_currentIndex + 1);
  void _prevPage() => _goToPage(_currentIndex - 1);

  void _onPointerDown(PointerDownEvent event) {
    // マウスの戻るボタン（ボタン4）で一覧に戻る
    if (event.buttons == kBackMouseButton) {
      Navigator.of(context).pop();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.controlLeft) ||
          HardwareKeyboard.instance.logicalKeysPressed
              .contains(LogicalKeyboardKey.controlRight)) {
        // Ctrl + ホイール: 拡大縮小（画像中心起点）
        setState(() {
          final delta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
          _scale = (_scale * delta).clamp(0.5, 8.0);
          if (_scale == 1.0) _offset = Offset.zero;
        });
      } else {
        // ホイールのみ: ページ送り
        if (event.scrollDelta.dy > 0) {
          _nextPage();
        } else if (event.scrollDelta.dy < 0) {
          _prevPage();
        }
      }
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _nextPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      _prevPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _goToPage(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _goToPage((_pages?.length ?? 1) - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _toggleFavorite(ImageSource image) async {
    final meta = {
      'name': image.name,
      'uri': image.uri,
      'thumbnailUrl': image.metadata?['thumbnailUrl'],
      ...?image.metadata,
    };
    await widget.favoritesStore.toggle(image.id, meta);
    setState(() {});
  }

  Future<void> _toggleDownload(ImageSource image) async {
    final key = 'full:${image.id}';
    final data = _fullImages[image.id];
    await widget.cacheManager.l3.toggle(key, data, {
      'name': image.name,
      'uri': image.uri,
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_isResolvingPages) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Listener(
          onPointerDown: _onPointerDown,
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: const Text('エラー', style: TextStyle(color: Colors.white)),
            ),
            body: Center(
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ),
        ),
      );
    }

    final pages = _pages!;
    final currentImage = pages[_currentIndex];
    final data = _fullImages[currentImage.id];
    final isFav = widget.favoritesStore.isFavorite(currentImage.id);
    final isDl =
        widget.cacheManager.l3.isDownloaded('full:${currentImage.id}');
    final cacheSource = _cacheSources[currentImage.id];

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: GestureDetector(
        onTap: () => setState(() => _showOverlay = !_showOverlay),
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -300) {
            _nextPage(); // 上スワイプ → 次
          } else if (velocity > 300) {
            _prevPage(); // 下スワイプ → 前
          }
        },
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                // 画像表示
                Center(
                  child: data != null
                      ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..translate(_offset.dx, _offset.dy) // ignore: deprecated_member_use
                            ..scale(_scale), // ignore: deprecated_member_use
                          child: Image.memory(data, fit: BoxFit.contain),
                        )
                      : const CircularProgressIndicator(),
                ),
                // オーバーレイ
                if (_showOverlay) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black54, Colors.transparent],
                        ),
                      ),
                      child: SafeArea(
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back,
                                  color: Colors.white),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Text(
                                currentImage.name,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (cacheSource != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Icon(
                                  cacheSource == CacheSource.network
                                      ? Icons.cloud_download
                                      : Icons.storage,
                                  color: Colors.white70,
                                  size: 16,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black54, Colors.transparent],
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: SafeArea(
                        top: false,
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  final authorId = currentImage.metadata?['authorId'];
                                  final authorName = currentImage.metadata?['author'] as String? ?? '';
                                  if (authorId != null) {
                                    Navigator.of(context).pop({
                                      'action': 'showUser',
                                      'userId': authorId,
                                      'userName': authorName,
                                    });
                                  }
                                },
                                child: Text(
                                  currentImage.metadata?['author']
                                          as String? ??
                                      '',
                                  style: const TextStyle(
                                    color: Colors.lightBlueAccent,
                                    fontSize: 12,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Colors.lightBlueAccent,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                isFav
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color:
                                    isFav ? Colors.redAccent : Colors.white,
                              ),
                              onPressed: () =>
                                  _toggleFavorite(currentImage),
                              tooltip: 'お気に入り',
                            ),
                            IconButton(
                              icon: Icon(
                                isDl
                                    ? Icons.download_done
                                    : Icons.download,
                                color:
                                    isDl ? Colors.greenAccent : Colors.white,
                              ),
                              onPressed: () =>
                                  _toggleDownload(currentImage),
                              tooltip: 'ダウンロード',
                            ),
                            Text(
                              pages.length > 1
                                  ? '${_currentIndex + 1} / ${pages.length}'
                                  : '',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
