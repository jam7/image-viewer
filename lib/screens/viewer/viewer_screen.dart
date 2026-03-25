import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/cache/cache_metadata.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/source_registry.dart';

final _log = Logger('Viewer');

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
  final Map<String, (int received, int total)> _loadProgress = {};
  bool _showOverlay = true;
  bool _isDownloading = false;
  (int received, int total)? _downloadProgress;
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
    _log.info('deactivate: cleared image data');
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _log.info('activate: reloading images');
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
    _log.info('openItem: index=$itemIndex/${widget.items.length}, name=${widget.items[itemIndex].name}');
    setState(() {
      _isResolvingPages = true;
      _error = null;
      _pages = null; // Prevent _goToPage from using stale pages during resolve
      _pageIndex = 0;
      _scale = 1.0;
      _offset = Offset.zero;
      // Release previous work's image data to prevent memory accumulation
      _fullImages.clear();
      _cacheSources.clear();
      _loadingStates.clear();
      _loadProgress.clear();
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
        if (pages.isEmpty) {
          setState(() {
            _error = 'No viewable images in ${item.name}';
            _isResolvingPages = false;
          });
        } else {
          setState(() {
            _pages = pages;
            _isResolvingPages = false;
          });
          _preloadAround(0);
        }
      }
    } catch (e, st) {
      _log.warning('resolvePages error', e, st);
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
    // PDF rendering is slow (~500ms/page, serial), so reduce lookahead
    final isPdf = pages.isNotEmpty && pages.first.metadata?['isPdfPage'] == true;
    final ahead = isPdf ? 2 : 4;
    for (var i = index - 1; i <= index + ahead; i++) {
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

    // Skip download for unsupported formats (e.g. ZIP inside ZIP)
    if (image.metadata?['unsupported'] == true) return;

    _loadingStates[image.id] = true;
    final key = 'full:${image.id}';
    _log.info('Loading full image: ${image.name} key=$key');

    try {
      final cached = await widget.cacheManager.get(key);
      if (cached != null) {
        _log.info('Cache hit: ${image.name} (${cached.data.length} bytes, ${cached.source})');
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
          () => provider.fetchFullImage(image, onProgress: (received, total) {
            if (mounted) {
              setState(() => _loadProgress[image.id] = (received, total));
            }
          }),
        );
        if (mounted) {
          setState(() {
            _fullImages[image.id] = Uint8List.fromList(result.data);
            _cacheSources[image.id] = result.source;
          });
        }
      }
    } catch (e, st) {
      _log.warning('loadFullImage error (${image.name})', e, st);
    } finally {
      _loadingStates[image.id] = false;
      _loadProgress.remove(image.id);
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
    _evictDistantPages(index, pages);
  }

  Widget _buildLoadingIndicator(String imageId) {
    final progress = _loadProgress[imageId];
    if (progress == null) {
      return const CircularProgressIndicator();
    }
    final (received, total) = progress;
    final fraction = total > 0 ? received / total : null;
    final receivedKB = (received / 1024).toStringAsFixed(0);
    final totalKB = total > 0 ? (total / 1024).toStringAsFixed(0) : '?';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(value: fraction),
        ),
        const SizedBox(height: 12),
        Text(
          '$receivedKB / $totalKB KB',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildDownloadProgress() {
    final (received, total) = _downloadProgress!;
    final item = widget.items[_itemIndex];
    final isPagesProgress = item.metadata?['isZip'] != true && item.metadata?['isPdf'] != true;

    final fraction = total > 0 ? received / total : null;
    final progressText = isPagesProgress
        ? '$received / $total pages'
        : '${(received / 1024).toStringAsFixed(0)} / ${(total / 1024).toStringAsFixed(0)} KB';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(value: fraction),
        ),
        const SizedBox(height: 12),
        Text(
          'Downloading ${item.name}',
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text(
          progressText,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  /// Release image data for pages far from [currentIndex] to prevent OOM
  /// on works with many pages. Keeps ±5 pages. Data is still in L1 cache
  /// so re-display is instant.
  void _evictDistantPages(int currentIndex, List<ImageSource> pages) {
    const keepRange = 5;
    final keysToKeep = <String>{};
    for (var i = currentIndex - keepRange; i <= currentIndex + keepRange; i++) {
      if (i >= 0 && i < pages.length) {
        keysToKeep.add(pages[i].id);
      }
    }
    _fullImages.removeWhere((key, _) => !keysToKeep.contains(key));
  }

  void _nextPage() {
    if (_pages != null && _pageIndex + 1 >= _pages!.length) {
      _nextItem(); // Last page: advance to next item
    } else {
      _goToPage(_pageIndex + 1);
    }
  }

  void _prevPage() {
    if (_pageIndex <= 0) {
      _prevItem(); // First page: go back to previous item
    } else {
      _goToPage(_pageIndex - 1);
    }
  }

  // --- 作品送り（リスト内、左右） ---

  void _nextItem() {
    if (_isResolvingPages) return; // Prevent concurrent _openItem
    if (_itemIndex + 1 >= widget.items.length) return;
    _itemIndex++;
    _openItem(_itemIndex);
  }

  void _prevItem() {
    if (_isResolvingPages) return; // Prevent concurrent _openItem
    if (_itemIndex <= 0) return;
    _itemIndex--;
    _openItem(_itemIndex);
  }

  // --- 入力ハンドリング ---

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      _log.info('pop via mouse back button');
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
    // 上下: 1ページ送り
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.space) {
      _nextPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _prevPage();
      return KeyEventResult.handled;
    }
    // PageDown/PageUp: 10ページ飛ばし
    if (key == LogicalKeyboardKey.pageDown) {
      _goToPage((_pageIndex + 10).clamp(0, (_pages?.length ?? 1) - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _goToPage((_pageIndex - 10).clamp(0, (_pages?.length ?? 1) - 1));
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
      _log.info('pop via ESC');
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
    final wasAdded = await widget.favoritesStore.toggle(image.id, meta);
    setState(() {});

    // Pixiv bookmark: add when favorited (best-effort, don't block UI)
    if (wasAdded && image.sourceKey?.startsWith('pixiv:') == true) {
      final illustId = image.metadata?['illustId'] as int?;
      if (illustId != null) {
        try {
          final provider = await widget.registry.resolve(image.sourceKey!, context);
          if (provider is PixivSource) {
            await provider.client.bookmarkAdd(illustId);
          }
        } catch (e, st) {
          _log.warning('Pixiv bookmark failed', e, st);
        }
      }
    }
  }

  /// Get the L3 download key for the current work (not page).
  String _workDownloadKey() {
    final item = widget.items[_itemIndex];
    return 'full:${item.id}';
  }

  /// Whether the current work is downloaded to L3.
  bool _isWorkDownloaded() {
    return widget.cacheManager.l3.isDownloaded(_workDownloadKey());
  }

  Future<void> _toggleDownload(ImageSource currentImage) async {
    final item = widget.items[_itemIndex];
    final workKey = _workDownloadKey();

    // Already downloaded → remove work and its pages
    if (widget.cacheManager.l3.isDownloaded(workKey)) {
      _log.info('Removing download: ${item.name} key=$workKey');
      final pages = _pages;
      if (pages != null) {
        for (final page in pages) {
          final pageKey = 'full:${page.id}';
          if (widget.cacheManager.l3.isDownloaded(pageKey)) {
            await widget.cacheManager.l3.remove(pageKey);
          }
        }
      }
      await widget.cacheManager.l3.remove(workKey);
      setState(() {});
      return;
    }

    _log.info('Downloading work: ${item.name} key=$workKey');

    final meta = {
      'name': item.name,
      'uri': item.uri,
      'sourceKey': item.sourceKey,
      ...?item.metadata,
    };

    // Single image (no pages or 1 page = the item itself)
    final pages = _pages;
    if (pages == null ||
        (pages.length == 1 && pages.first.metadata?['isPdfPage'] != true &&
         pages.first.metadata?['isZipEntry'] != true)) {
      final data = _fullImages[currentImage.id];
      if (data == null) {
        _log.warning('Download skipped: image not loaded yet (${item.name})');
        return;
      }
      await widget.cacheManager.l3.put(workKey, data, meta);
      _log.info('Downloaded single image: ${item.name} (${data.length} bytes)');
      setState(() {});
      return;
    }

    // Multi-page work: show loading screen
    setState(() {
      _isDownloading = true;
      _downloadProgress = null;
    });

    try {
      final provider = item.sourceKey != null
          ? await widget.registry.resolve(item.sourceKey!, context)
          : null;
      if (provider == null || !mounted) return;

      Uint8List? workData;

      if (item.metadata?['isPdf'] == true) {
        // PDF: get bytes from cache (already downloaded during resolvePages)
        _log.info('Downloading PDF from cache: ${item.name}');
        final cached = await widget.cacheManager.get('full:${item.id}');
        workData = cached != null ? Uint8List.fromList(cached.data) : null;
      } else if (item.metadata?['isZip'] == true) {
        // ZIP: stream directly to L3 file (avoid loading entire ZIP into memory)
        _log.info('Downloading ZIP from source: ${item.name}');
        final (:stream, :fileSize, :close) = await provider.openReadStream(item);
        final saved = await widget.cacheManager.l3.putFromStream(workKey, stream, meta,
          total: fileSize,
          onProgress: (received, total) {
            if (mounted) {
              setState(() => _downloadProgress = (received, total));
            }
          },
          isCancelled: () => !_isDownloading || !mounted,
        );
        await close();
        if (saved) {
          _log.info('Downloaded ZIP: ${item.name} (${(fileSize / 1024).toStringAsFixed(0)} KB)');
        } else {
          _log.info('Download cancelled: ${item.name}');
        }
        if (mounted) {
          setState(() {
            _isDownloading = false;
            _downloadProgress = null;
          });
        }
        return;
      } else {
        // Multi-page (e.g. Pixiv): download all pages individually
        _log.info('Downloading ${pages.length} pages: ${item.name}');
        int received = 0;
        final savedPageKeys = <String>[];
        final totalPages = pages.length;
        for (var i = 0; i < pages.length; i++) {
          if (!mounted || !_isDownloading) {
            // Cancel: remove pages saved so far
            _log.info('Download cancelled at page ${i + 1}/$totalPages: ${item.name}');
            for (final k in savedPageKeys) {
              await widget.cacheManager.l3.remove(k);
            }
            return;
          }
          final page = pages[i];
          final pageKey = 'full:${page.id}';
          // Skip if already in L3
          if (!widget.cacheManager.l3.isDownloaded(pageKey)) {
            final pageData = _fullImages[page.id] ??
                (await widget.cacheManager.get(pageKey))?.data as Uint8List? ??
                await provider.fetchFullImage(page);
            await widget.cacheManager.l3.put(pageKey, Uint8List.fromList(pageData), {
              'name': page.name,
              'uri': page.uri,
              'workKey': workKey,
              ...?page.metadata,
            });
            savedPageKeys.add(pageKey);
          } else {
            savedPageKeys.add(pageKey); // track for cleanup on cancel
          }
          received = i + 1;
          if (mounted) {
            setState(() => _downloadProgress = (received, totalPages));
          }
        }
        // Mark work itself as downloaded (empty data, metadata only)
        await widget.cacheManager.l3.put(workKey, Uint8List(0), meta);
        _log.info('Downloaded all pages: ${item.name}');
        setState(() {
          _isDownloading = false;
          _downloadProgress = null;
        });
        return;
      }

      if (workData != null && mounted) {
        await widget.cacheManager.l3.put(workKey, workData, meta);
        _log.info('Downloaded work: ${item.name} (${(workData.length / 1024).toStringAsFixed(0)} KB)');
      }
    } catch (e, st) {
      _log.warning('Download work failed', e, st);
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = null;
        });
      }
    }
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    if (_isResolvingPages) {
      return Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Listener(
          onPointerDown: _onPointerDown,
          child: const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }

    if (_isDownloading) {
      return Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            setState(() => _isDownloading = false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Listener(
          onPointerDown: _onPointerDown,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: _downloadProgress != null
                  ? _buildDownloadProgress()
                  : const CircularProgressIndicator(),
            ),
          ),
        ),
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
    final isDl = _isWorkDownloaded();
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
          if (velocity < -500) {
            _nextItem(); // 左スワイプ → 次の作品
          } else if (velocity > 500) {
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
                  child: currentImage.metadata?['unsupported'] == true
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.block, color: Colors.white38, size: 64),
                            const SizedBox(height: 16),
                            Text(
                              currentImage.name.split(') ').last,
                              style: const TextStyle(color: Colors.white54),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Unsupported format',
                              style: TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                          ],
                        )
                      : data != null
                          ? Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..translate(_offset.dx, _offset.dy) // ignore: deprecated_member_use
                                ..scale(_scale), // ignore: deprecated_member_use
                              child: Image.memory(data, fit: BoxFit.contain),
                            )
                          : _buildLoadingIndicator(currentImage.id),
                ),
                // Page sidebar (right edge)
                if (pages.length > 1)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: _buildPageSidebar(pages),
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
                                    _log.info('pop with showUser: authorId=$authorId, authorName=$authorName');
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

  Widget _buildPageSidebar(List<ImageSource> pages) {
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        final renderBox = details.localPosition;
        final height = context.size?.height ?? 1;
        final ratio = (renderBox.dy / height).clamp(0.0, 1.0);
        final targetPage = (ratio * (pages.length - 1)).round();
        if (targetPage != _pageIndex) {
          _goToPage(targetPage);
        }
      },
      onTapDown: (details) {
        final height = context.size?.height ?? 1;
        final ratio = (details.localPosition.dy / height).clamp(0.0, 1.0);
        final targetPage = (ratio * (pages.length - 1)).round();
        _goToPage(targetPage);
      },
      child: Container(
        width: 40,
        color: Colors.black26,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final totalHeight = constraints.maxHeight;
            final indicatorPos = pages.length > 1
                ? (_pageIndex / (pages.length - 1)) * (totalHeight - 24)
                : 0.0;
            return Stack(
              children: [
                Positioned(
                  top: indicatorPos,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${_pageIndex + 1}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ],
            );
          },
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
