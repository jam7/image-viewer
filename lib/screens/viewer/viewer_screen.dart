import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/cache/cache_metadata.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/source_registry.dart';

/// 画像ビューア画面。
/// - 上下スワイプ / マウスホイール / 上下キー / Page Up・Down: ページ送り（作品内）
/// - 左右スワイプ / 左右キー: 作品送り（リスト内）
/// - Ctrl + マウスホイール: 拡大縮小
/// - ESC / マウスバック / 左端外スワイプ: 一覧に戻る
class ViewerScreen extends StatefulWidget {
  final List<ImageSource> items; // 作品リスト
  final int initialIndex; // 最初に表示する作品
  final SourceRegistry registry;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;

  const ViewerScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
    required this.registry,
    required this.cacheManager,
    required this.favoritesStore,
  });

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  // 作品リスト内の位置
  late int _itemIndex;
  // 現在の作品のページリスト
  List<ImageSource>? _pages;
  int _pageIndex = 0;
  bool _isResolvingPages = true;
  String? _error;

  // 表示状態
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  final Map<String, Uint8List> _fullImages = {};
  final Map<String, CacheSource> _cacheSources = {};
  final Map<String, bool> _loadingStates = {};
  bool _showOverlay = true;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _itemIndex = widget.initialIndex;
    // Defer to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openItem(_itemIndex);
    });
  }

  @override
  void deactivate() {
    // Release image data when pushed behind another screen.
    // Data will be reloaded when this screen becomes visible again.
    _fullImages.clear();
    _cacheSources.clear();
    _loadingStates.clear();
    print('[Viewer] deactivate: cleared image data');
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    print('[Viewer] activate: reloading images');
    // Reload images when returning to this screen
    if (_pages != null) {
      _preloadAround(_pageIndex);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 作品を開く: resolvePages でページ展開してプリロード開始。
  Future<void> _openItem(int itemIndex) async {
    print('[Viewer] openItem: index=$itemIndex/${widget.items.length}, name=${widget.items[itemIndex].name}');
    setState(() {
      _isResolvingPages = true;
      _error = null;
      _pageIndex = 0;
      _scale = 1.0;
      _offset = Offset.zero;
      // Release previous work's image data to prevent memory accumulation
      _fullImages.clear();
      _cacheSources.clear();
      _loadingStates.clear();
    });

    try {
      final item = widget.items[itemIndex];
      final provider = item.sourceKey != null
          ? await widget.registry.resolve(item.sourceKey!, context)
          : null;
      if (!mounted) return;

      List<ImageSource> pages;
      if (provider != null) {
        pages = await provider.resolvePages(item);
      } else {
        pages = [item];
      }

      if (mounted) {
        setState(() {
          _pages = pages;
          _isResolvingPages = false;
        });
        _preloadAround(0);
      }
    } catch (e, st) {
      print('[Viewer] resolvePages error: $e\n$st');
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
        _loadFullImage(pages[i]);
      }
    }
  }

  Future<void> _loadFullImage(ImageSource image) async {
    if (_fullImages.containsKey(image.id) ||
        _loadingStates[image.id] == true) {
      return;
    }

    _loadingStates[image.id] = true;
    final key = 'full:${image.id}';
    print('[Viewer] Loading full image: ${image.name} key=$key');

    try {
      final cached = await widget.cacheManager.get(key);
      if (cached != null) {
        print('[Viewer] Cache hit: ${image.name} (${cached.data.length} bytes, ${cached.source})');
        if (mounted) {
          setState(() {
            _fullImages[image.id] = Uint8List.fromList(cached.data);
            _cacheSources[image.id] = cached.source;
          });
        }
      } else {
        final provider = image.sourceKey != null
            ? await widget.registry.resolve(image.sourceKey!, context)
            : null;
        if (provider == null) return;
        final result = await widget.cacheManager.fetchAndCache(
          key,
          () => provider.fetchFullImage(image),
        );
        if (mounted) {
          setState(() {
            _fullImages[image.id] = Uint8List.fromList(result.data);
            _cacheSources[image.id] = result.source;
          });
        }
      }
    } catch (e, st) {
      print('[Viewer] loadFullImage error (${image.name}): $e\n$st');
    } finally {
      _loadingStates[image.id] = false;
    }
  }

  // --- ページ送り（作品内、上下） ---

  void _goToPage(int index) {
    final pages = _pages;
    if (pages == null) return;
    if (index < 0 || index >= pages.length) return;
    setState(() {
      _pageIndex = index;
      _scale = 1.0;
      _offset = Offset.zero;
    });
    _preloadAround(index);
  }

  void _nextPage() => _goToPage(_pageIndex + 1);
  void _prevPage() => _goToPage(_pageIndex - 1);

  // --- 作品送り（リスト内、左右） ---

  void _nextItem() {
    if (_itemIndex + 1 >= widget.items.length) return;
    _itemIndex++;
    _openItem(_itemIndex);
  }

  void _prevItem() {
    if (_itemIndex <= 0) return;
    _itemIndex--;
    _openItem(_itemIndex);
  }

  // --- 入力ハンドリング ---

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      print('[Viewer] pop via mouse back button');
      Navigator.of(context).pop();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (HardwareKeyboard.instance.logicalKeysPressed
              .contains(LogicalKeyboardKey.controlLeft) ||
          HardwareKeyboard.instance.logicalKeysPressed
              .contains(LogicalKeyboardKey.controlRight)) {
        setState(() {
          final delta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
          _scale = (_scale * delta).clamp(0.5, 8.0);
          if (_scale == 1.0) _offset = Offset.zero;
        });
      } else {
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
    // 上下: ページ送り
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _nextPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      _prevPage();
      return KeyEventResult.handled;
    }
    // 左右: 作品送り
    if (key == LogicalKeyboardKey.arrowRight) {
      _nextItem();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _prevItem();
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
      print('[Viewer] pop via ESC');
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // --- お気に入り / ダウンロード ---

  Future<void> _toggleFavorite(ImageSource image) async {
    final meta = {
      'name': image.name,
      'uri': image.uri,
      'sourceKey': image.sourceKey ?? 'pixiv:default',
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

  // --- UI ---

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
    final currentImage = pages[_pageIndex];
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
            _nextPage();
          } else if (velocity > 300) {
            _prevPage();
          }
        },
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -300) {
            _nextItem(); // 左スワイプ → 次の作品
          } else if (velocity > 300) {
            _prevItem(); // 右スワイプ → 前の作品
          }
        },
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
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
                                    print('[Viewer] pop with showUser: authorId=$authorId, authorName=$authorName');
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
                              _buildPositionText(pages),
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

  String _buildPositionText(List<ImageSource> pages) {
    final parts = <String>[];
    if (pages.length > 1) {
      parts.add('${_pageIndex + 1}/${pages.length}');
    }
    if (widget.items.length > 1) {
      parts.add('[${_itemIndex + 1}/${widget.items.length}]');
    }
    return parts.join(' ');
  }
}
