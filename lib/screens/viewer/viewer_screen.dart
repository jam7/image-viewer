import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

import '../../models/image_source.dart';
import '../../models/viewer_mark.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/cache/cache_metadata.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/image_source_provider.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../../widgets/thumbnail_result.dart';
import 'rendered_pages.dart';
import 'viewer_video_controls.dart';
import 'viewer_video_page.dart';

final _log = Logger('Viewer');

/// 画像ビューア画面。
/// - 上下スワイプ / マウスホイール / 上下キー / Page Up・Down: ページ送り（作品内）
/// - 左右スワイプ / 左右キー: 作品送り（リスト内）
/// - Ctrl + マウスホイール: 拡大縮小
/// - ESC / マウスバック / 左端外スワイプ: 一覧に戻る
class ViewerScreen extends StatefulWidget {
  final List<ImageSource> items; // 作品リスト
  /// Which of [items] is showing. Held by the caller rather than here, so that
  /// a caller for whom this is a place in a tab can keep the address in step
  /// with it (ADR 010). [onIndexChanged] is how this screen asks to move.
  final int index;
  final ValueChanged<int>? onIndexChanged;

  /// Leave the viewer: a step back in the tab's history, onto the list this
  /// was opened from.
  final VoidCallback onClose;

  /// Room to leave at the top for whatever the caller is drawing over us.
  final double topInset;

  /// Whether the viewer's own overlay is showing. Reported because the header
  /// above and the system bars go with it: reading a picture means seeing the
  /// picture, and everything else steps out of the way together (ADR 010).
  final ValueChanged<bool>? onOverlayChanged;

  /// What was opened is a list rather than one thing to look at — see
  /// [NotAnItemException]. Null leaves the failure on screen.
  final VoidCallback? onNotAnItem;

  /// How far into this work the reader had got last time, and where to put
  /// that back when they leave. Null for a caller with nowhere to keep it,
  /// which then starts every visit at the first page.
  final ViewerMark? mark;
  final ValueChanged<ViewerMark>? onMark;

  /// Follow this work's author, or one of its tags, in place. Null where the
  /// source has no such thing — only Pixiv works carry them.
  final void Function(int userId, String userName)? onShowAuthor;
  final ValueChanged<String>? onSearchTag;

  final SourceRegistry registry;
  final SmbProxyServer proxyServer;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;

  /// Open this work's author, or one of its tags, in a new tab — without
  /// closing the viewer. Long-pressing a chip means "alongside", and leaving
  /// the page the reader is on to honour that is the opposite of alongside.
  ///
  /// Null when whoever pushed the viewer has no tab set to add to; the request
  /// then goes back through the pop result, as it did before tabs existed.
  final void Function(int userId, String userName)? onOpenAuthorInNewTab;
  final void Function(String tag)? onOpenTagSearchInNewTab;

  const ViewerScreen({
    super.key,
    required this.items,
    this.index = 0,
    this.onIndexChanged,
    required this.onClose,
    this.topInset = 0,
    this.onOverlayChanged,
    this.onNotAnItem,
    this.mark,
    this.onMark,
    this.onShowAuthor,
    this.onSearchTag,
    required this.registry,
    required this.proxyServer,
    required this.cacheManager,
    required this.favoritesStore,
    this.onOpenAuthorInNewTab,
    this.onOpenTagSearchInNewTab,
  });

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  /// Which page of the current work is showing. The work itself is
  /// [ViewerScreen.index], which the caller owns.
  // 現在の作品のページリスト
  List<ImageSource>? _pages;
  int _pageIndex = 0;
  bool _isResolvingPages = true;
  String? _error;

  // 表示状態
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  final Map<String, Uint8List> _fullImages = {};

  /// Pages this app drew rather than fetched — PDF, today. Kept as pixels
  /// because encoding one costs several times what drawing it does, and
  /// because nothing else would ever read the encoded form back
  /// (ADR 012 の続き). Disposal lives in the class, not here.
  final _rendered = RenderedPages();
  final Map<String, CacheSource> _cacheSources = {};
  final Map<String, bool> _loadingStates = {};
  final Map<String, (int received, int total)> _loadProgress = {};

  /// Pages that could not be read, by id, with what went wrong.
  ///
  /// Kept because a page with no bytes and no answer looks exactly like a page
  /// still arriving, and stays looking like it for as long as the viewer is
  /// open. The reader is owed the difference.
  final Map<String, String> _loadFailures = {};
  bool _showOverlay = true;

  /// The player of the video on screen, if that is what is on screen. Handed
  /// up so its controls can go in this overlay rather than in one of its own.
  Player? _video;

  /// Whether the video on screen is playing, kept across the swap so the next
  /// one can carry on: the next thing does what the last thing was doing.
  bool _videoWasPlaying = false;

  /// Whether a video arriving now should start. Opening one deliberately — a
  /// tap in the list, an address pasted — means play it; swiping past one
  /// means play it only if what we swiped away from was playing; and coming
  /// back to a tab means it should not, which is what the mark says.
  bool _autoplayNext = true;

  /// Set by pressing play on a video that arrived stopped. Held here rather
  /// than in the page below because the button is up here, in the overlay,
  /// beside the bar showing where the video was left.
  bool _playAsked = false;

  /// Where the video on screen has got to, followed while it plays so that
  /// leaving does not have to catch it. Starts at whatever the mark said, so
  /// that arriving and leaving again without pressing play keeps the place.
  Duration _videoAt = Duration.zero;
  Duration _videoTotal = Duration.zero;
  StreamSubscription<Duration>? _videoWatch;
  StreamSubscription<Duration>? _videoTotalWatch;

  /// Hides the overlay when nothing has happened for a while. Reading is long
  /// stretches of looking with no input at all, and the chrome has no business
  /// sitting there through it.
  static const _idleBeforeHiding = Duration(seconds: 3);
  Timer? _idle;
  bool _sidebarActive = false;
  bool _isDownloading = false;
  (int received, int total)? _downloadProgress;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Defer to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openItem(widget.index);
      _setOverlay(true); // and start the countdown
    });
  }

  @override
  void deactivate() {
    // Release image data when pushed behind another screen.
    // Data will be reloaded when this screen becomes visible again.
    _fullImages.clear();
    _rendered.clear();
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
    _reportMark();
    _idle?.cancel();
    _videoWatch?.cancel();
    _videoTotalWatch?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// Hand back where the reader got to, for the next time this place is shown.
  ///
  /// Always as stopped: this runs when the viewer goes away, and on a tab
  /// switch that is a place which may not be returned to for hours. Swiping
  /// along the list does not come through here — the screen stays, and its own
  /// rule carries the playing on to the next video.
  void _reportMark() {
    final onMark = widget.onMark;
    if (onMark == null || _pages == null) return;
    if (widget.index >= widget.items.length) return;
    onMark(ViewerMark(
      widget.items[widget.index].id,
      page: _pageIndex,
      at: _videoAt,
      total: _videoTotal,
      paused: true,
    ));
  }

  /// Whether a video is sitting where it was left, waiting to be started
  /// again. True only before anything is opened: once there is a player, the
  /// position it reports is the truth.
  bool get _resting => _video == null && _videoTotal > Duration.zero;

  /// The row under a video: its controls while it is open, and where it was
  /// left while it is not. Null when what is on screen is not a video.
  Widget? _videoBar() {
    if (_video != null) return ViewerVideoControls(player: _video!);
    if (!_resting) return null;
    return ViewerVideoRestingBar(
      at: _videoAt,
      total: _videoTotal,
      onPlay: () => setState(() => _playAsked = true),
    );
  }

  /// Follow the video on screen while it plays.
  ///
  /// media_kit reports the position on a stream, and the page holding the
  /// player is disposed before this screen is — so asking at the end would be
  /// asking something that has already gone. The last value seen is the answer.
  void _attachVideo(Player? player) {
    _videoWatch?.cancel();
    _videoTotalWatch?.cancel();
    _videoWatch = player?.stream.position.listen((at) => _videoAt = at);
    _videoTotalWatch = player?.stream.duration.listen((d) => _videoTotal = d);
    setState(() => _video = player);
  }

  /// 作品を開く: resolvePages でページ展開してプリロード開始。
  Future<void> _openItem(int itemIndex) async {
    _log.info(
      'openItem: index=$itemIndex/${widget.items.length}, name=${widget.items[itemIndex].name}',
    );
    setState(_forgetPreviousItem);

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

      if (!mounted) return;
      if (pages.isEmpty) {
        setState(() {
          _error = 'No viewable images in ${item.name}';
          _isResolvingPages = false;
        });
        return;
      }
      setState(() => _arriveAt(item, pages));
      _preloadAround(_pageIndex);
    } on NotAnItemException catch (e) {
      // The address named a list after all, which only an address from outside
      // can get wrong. Showing "cannot read this" would be true and useless;
      // the caller can go to the listing (ADR 010).
      _log.info('not an item: ${e.path}');
      widget.onNotAnItem?.call();
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

  /// Show [pages], picking up where the mark left off: the page that was being
  /// read, and for a video the second it was stopped at.
  ///
  /// A mark left by another work is ignored — the place may have moved on
  /// between the last screen writing one and this one opening.
  void _arriveAt(ImageSource item, List<ImageSource> pages) {
    _pages = pages;
    _isResolvingPages = false;
    final mark = widget.mark?.forItem(item.id);
    if (mark == null) return;
    _pageIndex = mark.page.clamp(0, pages.length - 1);
    _autoplayNext = !mark.paused;
    _videoAt = mark.at;
    _videoTotal = mark.total;
  }

  void _preloadAround(int index) {
    final pages = _pages;
    if (pages == null) return;
    // PDF rendering is slow (~500ms/page, serial), so reduce lookahead
    final isPdf =
        pages.isNotEmpty && pages.first.metadata?['isPdfPage'] == true;
    final ahead = isPdf ? 2 : 4;
    // Load current page first, then ahead, then behind
    _loadFullImage(pages[index]);
    for (var i = index + 1; i <= index + ahead; i++) {
      if (i < pages.length) {
        _loadFullImage(pages[i]);
      }
    }
    if (index - 1 >= 0) {
      _loadFullImage(pages[index - 1]);
    }
  }

  Future<void> _loadFullImage(ImageSource image) async {
    if (!_worthLoading(image)) return;

    _loadingStates[image.id] = true;
    // Read before the first await: after one, this context may be gone.
    final displayPx = _displaySizePx(context);
    _log.info('Loading full image: ${image.name} key=full:${image.id}');

    try {
      if (await _showCached(image)) return;
      final provider = image.sourceKey != null
          ? await widget.registry.resolve(image.sourceKey!, context)
          : null;
      if (provider == null) return;
      if (await _showDrawn(image, provider, displayPx)) return;
      await _showFetched(image, provider, displayPx);
    } on NotAnItemException catch (e) {
      // Reading it is how we found out, because a plain image resolves to a
      // single page without touching the network. Same answer as in
      // [_openItem]: the caller goes to the listing (ADR 010).
      _log.info('not an item: ${e.path}');
      widget.onNotAnItem?.call();
    } catch (e, st) {
      _log.warning('loadFullImage error (${image.name})', e, st);
      if (mounted) setState(() => _loadFailures[image.id] = '$e');
    } finally {
      _loadingStates[image.id] = false;
      _loadProgress.remove(image.id);
    }
  }

  /// Whether it was already somewhere in the cache.
  Future<bool> _showCached(ImageSource image) async {
    final cached = await widget.cacheManager.get('full:${image.id}');
    if (cached == null) return false;
    _log.info('Cache hit: ${image.name} '
        '(${cached.data.length} bytes, ${cached.source})');
    if (mounted) {
      setState(() {
        _fullImages[image.id] = Uint8List.fromList(cached.data);
        _cacheSources[image.id] = cached.source;
      });
    }
    return true;
  }

  /// Whether this is a page the source draws rather than fetches.
  ///
  /// One that is comes over as pixels and stops there: there is nothing to
  /// fetch and nothing worth storing, since encoding it costs several times
  /// what drawing it does (ADR 012 の続き).
  Future<bool> _showDrawn(
      ImageSource image, ImageSourceProvider provider, Size displayPx) async {
    final drawing = provider.renderPage(image, maxDisplayPx: displayPx);
    if (drawing == null) return false;
    final drawn = await drawing;
    if (!mounted) {
      // Nobody else holds it, and nothing else will let it go.
      drawn.dispose();
      return true;
    }
    setState(() => _rendered.put(image.id, drawn));
    return true;
  }

  Future<void> _showFetched(
      ImageSource image, ImageSourceProvider provider, Size displayPx) async {
    final result = await widget.cacheManager.fetchAndCache(
      'full:${image.id}',
      () => provider.fetchFullImage(
        image,
        maxDisplayPx: displayPx,
        onProgress: (received, total) {
          if (mounted) {
            setState(() => _loadProgress[image.id] = (received, total));
          }
        },
      ),
    );
    if (mounted) {
      setState(() {
        _fullImages[image.id] = Uint8List.fromList(result.data);
        _cacheSources[image.id] = result.source;
      });
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

  /// 48x48 spinner with caption lines below, shared by the loading and
  /// download progress overlays.
  Widget _progressColumn(double? fraction, List<Text> captions) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(value: fraction),
        ),
        for (var i = 0; i < captions.length; i++) ...[
          SizedBox(height: i == 0 ? 12 : 4),
          captions[i],
        ],
      ],
    );
  }

  /// Show or hide everything that is not the picture. Restarts the idle
  /// countdown, so showing it is always followed by hiding it again.
  void _setOverlay(bool show) {
    if (_showOverlay != show) {
      setState(() => _showOverlay = show);
      widget.onOverlayChanged?.call(show);
    }
    _idle?.cancel();
    if (show) _idle = Timer(_idleBeforeHiding, () => _setOverlay(false));
  }

  /// Nothing of the last item survives into this one: not its pages, not how
  /// far it was zoomed, and above all not its bytes, which is what would
  /// otherwise pile up one work at a time.
  void _forgetPreviousItem() {
    _isResolvingPages = true;
    _error = null;
    _pages = null; // Prevent _goToPage from using stale pages during resolve
    _pageIndex = 0;
    _scale = 1.0;
    _offset = Offset.zero;
    _fullImages.clear();
    _rendered.clear();
    _cacheSources.clear();
    _loadingStates.clear();
    _loadProgress.clear();
    _loadFailures.clear();
    // Nor how far into the last video we were, nor a press of play meant for
    // it. _autoplayNext is the exception: what the last one was doing is
    // exactly what the next one is asked to carry on.
    _playAsked = false;
    _videoAt = Duration.zero;
    _videoTotal = Duration.zero;
  }

  static bool _isVideo(ImageSource item) => item.metadata?['isVideo'] == true;

  /// Whether this one's bytes are worth fetching at all.
  bool _worthLoading(ImageSource image) {
    if (_fullImages.containsKey(image.id) || _rendered.contains(image.id)) {
      return false;
    }
    if (_loadingStates[image.id] == true) return false;
    // Already tried and failed. Asking again on every scroll would hammer a
    // source that has just said no; asking again is the reader's to do.
    if (_loadFailures.containsKey(image.id)) return false;
    // Unsupported formats (a ZIP inside a ZIP) have nothing to show.
    if (image.metadata?['unsupported'] == true) return false;
    // A video is streamed through the proxy a piece at a time. Fetching it
    // here would pull the whole file into memory and the cache to show one.
    return !_isVideo(image);
  }

  /// The still already made for the grid, if it is still in memory.
  ThumbnailResult? _posterFor(ImageSource item) {
    final data = _fullImages[item.id];
    return data == null ? null : ThumbnailData(data);
  }

  /// What went wrong with this page, if anything did — and a way to ask
  /// again, since the usual reason is a share that went away for a moment.
  Widget? _buildUnreadable(ImageSource image) {
    final failure = _loadFailures[image.id];
    if (failure == null) return null;
    return GestureDetector(
      onTap: () {
        setState(() => _loadFailures.remove(image.id));
        _loadFullImage(image);
      },
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.broken_image, color: Colors.white38, size: 64),
            const SizedBox(height: 12),
            const Text(
              '読み込めませんでした。タップで再試行',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              failure,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white30, fontSize: 11),
            ),
          ],
        ),
      ),
    );
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
    return _progressColumn(fraction, [
      Text(
        '$receivedKB / $totalKB KB',
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
    ]);
  }

  Widget _buildDownloadProgress() {
    final (received, total) = _downloadProgress!;
    final item = widget.items[widget.index];
    final isPagesProgress =
        item.metadata?['isZip'] != true && item.metadata?['isPdf'] != true;

    final fraction = total > 0 ? received / total : null;
    final progressText = isPagesProgress
        ? '$received / $total pages'
        : '${(received / 1024).toStringAsFixed(0)} / ${(total / 1024).toStringAsFixed(0)} KB';
    return _progressColumn(fraction, [
      Text(
        'Downloading ${item.name}',
        style: const TextStyle(color: Colors.white54, fontSize: 14),
      ),
      Text(
        progressText,
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
    ]);
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
    _rendered.keepOnly(keysToKeep);
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

  void _nextItem() => _goToItem(widget.index + 1);

  void _prevItem() => _goToItem(widget.index - 1);

  /// Move to another work in the list. The caller is told rather than a field
  /// being bumped: for a tab this is a change of address, and the two would
  /// drift apart if this screen kept its own idea of where it was.
  void _goToItem(int index) {
    if (_isResolvingPages) return; // Prevent concurrent _openItem
    if (index < 0 || index >= widget.items.length) return;
    final move = widget.onIndexChanged;
    if (move != null) {
      move(index);
      return;
    }
    _openItem(index);
  }

  @override
  void didUpdateWidget(ViewerScreen old) {
    super.didUpdateWidget(old);
    if (widget.index == old.index) return;
    // Arrived by moving along the list, rather than by opening this place.
    _autoplayNext = _videoWasPlaying;
    _openItem(widget.index);
  }

  // --- 入力ハンドリング ---

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      _log.info('leaving via mouse back button');
      widget.onClose();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (HardwareKeyboard.instance.logicalKeysPressed.contains(
            LogicalKeyboardKey.controlLeft,
          ) ||
          HardwareKeyboard.instance.logicalKeysPressed.contains(
            LogicalKeyboardKey.controlRight,
          )) {
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
      _log.info('leaving via ESC');
      widget.onClose();
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
          final provider = await widget.registry.resolve(
            image.sourceKey!,
            context,
          );
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
    final item = widget.items[widget.index];
    return 'full:${item.id}';
  }

  /// Whether the current work is downloaded to L3.
  bool _isWorkDownloaded() {
    return widget.cacheManager.l3.isDownloaded(_workDownloadKey());
  }

  Future<void> _toggleDownload(ImageSource currentImage) async {
    final workKey = _workDownloadKey();
    if (widget.cacheManager.l3.isDownloaded(workKey)) {
      await _removeDownload(workKey);
    } else {
      await _downloadWork(currentImage, workKey);
    }
  }

  /// Remove the downloaded work and all of its downloaded pages from L3.
  Future<void> _removeDownload(String workKey) async {
    final item = widget.items[widget.index];
    _log.info('Removing download: ${item.name} key=$workKey');
    final pages = _pages;
    if (pages != null) {
      for (final page in pages) {
        if (widget.cacheManager.l3.isDownloaded(_pageKey(page))) {
          await widget.cacheManager.l3.remove(_pageKey(page));
        }
      }
    }
    await widget.cacheManager.l3.remove(workKey);
    setState(() {});
  }

  /// Download the current work to L3. Four kinds of thing arrive four ways:
  /// the picture already on screen, a PDF, a ZIP, or a work of many pictures.
  Future<void> _downloadWork(ImageSource currentImage, String workKey) async {
    final item = widget.items[widget.index];
    _log.info('Downloading work: ${item.name} key=$workKey');

    final pages = _pages;
    if (pages == null || _isSinglePage(pages)) {
      await _saveSingleImage(currentImage, workKey);
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = null;
    });
    try {
      final provider = item.sourceKey != null
          ? await widget.registry.resolve(item.sourceKey!, context)
          : null;
      if (provider == null || !mounted) return;
      if (item.metadata?['isPdf'] == true) {
        await _savePdf(item, workKey);
      } else if (item.metadata?['isZip'] == true) {
        await _saveZip(provider, item, workKey);
      } else {
        await _saveAllPages(provider, pages, workKey);
      }
    } catch (e, st) {
      _log.warning('Download work failed', e, st);
    } finally {
      // Every way out passes through here, cancelled or not. Each branch used
      // to put the screen back itself, three copies of the same four lines.
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = null;
        });
      }
    }
  }

  /// Whether the work is the picture on screen and nothing more.
  ///
  /// One page is not enough to say so: a one-page PDF and a ZIP holding a
  /// single picture both have a container to fetch behind them.
  static bool _isSinglePage(List<ImageSource> pages) =>
      pages.length == 1 &&
      pages.first.metadata?['isPdfPage'] != true &&
      pages.first.metadata?['isZipEntry'] != true;

  /// What is stored beside the bytes, so that a downloaded work can be shown
  /// without the source it came from.
  Map<String, dynamic> _metaFor(ImageSource item) => {
    'name': item.name,
    'uri': item.uri,
    'sourceKey': item.sourceKey,
    ...?item.metadata,
  };

  String _pageKey(ImageSource page) => 'full:${page.id}';

  /// The picture on screen is the whole work, and it is already in memory:
  /// what would be fetched is what is being looked at.
  Future<void> _saveSingleImage(
    ImageSource currentImage,
    String workKey,
  ) async {
    final item = widget.items[widget.index];
    final data = _fullImages[currentImage.id];
    if (data == null) {
      _log.warning('Download skipped: image not loaded yet (${item.name})');
      return;
    }
    await widget.cacheManager.l3.put(workKey, data, _metaFor(item));
    _log.info('Downloaded single image: ${item.name} (${data.length} bytes)');
    setState(() {});
  }

  /// The PDF is in the cache already: rendering even its first page meant
  /// fetching the whole file.
  Future<void> _savePdf(ImageSource item, String workKey) async {
    _log.info('Downloading PDF from cache: ${item.name}');
    final cached = await widget.cacheManager.get(_pageKey(item));
    if (cached == null || !mounted) return;
    final data = Uint8List.fromList(cached.data);
    await widget.cacheManager.l3.put(workKey, data, _metaFor(item));
    _log.info(
      'Downloaded work: ${item.name} (${(data.length / 1024).toStringAsFixed(0)} KB)',
    );
  }

  /// Streamed straight into the file. A ZIP is a whole book, and holding one
  /// in memory to write it out again is how a large one ends the app.
  Future<void> _saveZip(
    ImageSourceProvider provider,
    ImageSource item,
    String workKey,
  ) async {
    _log.info('Downloading ZIP from source: ${item.name}');
    final (:stream, :fileSize, :close) = await provider.openReadStream(item);
    final saved = await widget.cacheManager.l3.putFromStream(
      workKey,
      stream,
      _metaFor(item),
      total: fileSize,
      onProgress: (received, total) {
        if (mounted) setState(() => _downloadProgress = (received, total));
      },
      isCancelled: () => !_isDownloading || !mounted,
    );
    await close();
    _log.info(
      saved
          ? 'Downloaded ZIP: ${item.name} '
                '(${(fileSize / 1024).toStringAsFixed(0)} KB)'
          : 'Download cancelled: ${item.name}',
    );
  }

  /// A work of many pictures, saved one at a time.
  ///
  /// Stopping half way takes back what was saved: half a work in the
  /// downloads is worse than none of it, because nothing afterwards says it
  /// is half.
  Future<void> _saveAllPages(
    ImageSourceProvider provider,
    List<ImageSource> pages,
    String workKey,
  ) async {
    final item = widget.items[widget.index];
    _log.info('Downloading ${pages.length} pages: ${item.name}');
    final saved = <String>[];
    for (var i = 0; i < pages.length; i++) {
      if (!mounted || !_isDownloading) {
        _log.info(
          'Download cancelled at page ${i + 1}/${pages.length}: ${item.name}',
        );
        await _removeAll(saved);
        return;
      }
      saved.add(await _savePage(provider, pages[i], workKey));
      if (mounted) setState(() => _downloadProgress = (i + 1, pages.length));
    }
    // The work itself holds no bytes: its pages are the download, and this
    // entry is what says they belong together.
    await widget.cacheManager.l3.put(workKey, Uint8List(0), _metaFor(item));
    _log.info('Downloaded all pages: ${item.name}');
  }

  /// Save one page unless it is there already, answering with its key either
  /// way — a page found in the downloads still belongs to this work, and has
  /// to come out again if the rest of it is cancelled.
  Future<String> _savePage(
    ImageSourceProvider provider,
    ImageSource page,
    String workKey,
  ) async {
    final key = _pageKey(page);
    if (widget.cacheManager.l3.isDownloaded(key)) return key;
    final data =
        _fullImages[page.id] ??
        (await widget.cacheManager.get(key))?.data as Uint8List? ??
        await provider.fetchFullImage(page);
    await widget.cacheManager.l3.put(key, Uint8List.fromList(data), {
      'name': page.name,
      'uri': page.uri,
      'workKey': workKey,
      ...?page.metadata,
    });
    return key;
  }

  Future<void> _removeAll(List<String> keys) async {
    for (final key in keys) {
      await widget.cacheManager.l3.remove(key);
    }
  }

  // --- UI ---

  /// Search a tag of the work being viewed. Handed back to the gallery to run,
  /// the same way "show this author" is, so the search lands in the tab's
  /// history instead of stacking another screen on top of the viewer.
  ///
  /// Say that a tab appeared. The strip is behind the viewer, so the chip
  /// showing up — the feedback everywhere else — cannot be seen from here.
  void _announceNewTab(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('新しいタブで開きました: $label'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// [newTab] carries a long-press: open it alongside and stay here.
  void _searchTag(String tag, {bool newTab = false}) {
    final alongside = widget.onOpenTagSearchInNewTab;
    if (newTab && alongside != null) {
      alongside(tag);
      _announceNewTab(tag);
      return; // the reader keeps their page
    }
    widget.onSearchTag?.call(tag);
  }

  void _showAuthor(ImageSource image, {bool newTab = false}) {
    final authorId = image.metadata?['authorId'] as int?;
    if (authorId == null) return;
    final authorName = image.metadata?['author'] as String? ?? '';
    final alongside = widget.onOpenAuthorInNewTab;
    if (newTab && alongside != null) {
      alongside(authorId, authorName);
      _announceNewTab(authorName);
      return;
    }
    widget.onShowAuthor?.call(authorId, authorName);
  }

  /// Horizontal, scrollable row of tappable tag chips for the current work.
  Widget _buildTagBar(List<String> tags) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: tags.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final tag = tags[i];
          return GestureDetector(
            onLongPress: () => _searchTag(tag, newTab: true),
            child: ActionChip(
              label: Text(tag),
              onPressed: () => _searchTag(tag),
              backgroundColor: Colors.white.withValues(alpha: 0.85),
              labelStyle: const TextStyle(color: Colors.black87, fontSize: 12),
              side: BorderSide.none,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final interruption = _buildInterruption();
    if (interruption != null) return interruption;

    final pages = _pages!;
    final currentImage = pages[_pageIndex];
    // Tags of the current work (Pixiv only; empty for other sources).
    final tags =
        (widget.items[widget.index].metadata?['tags'] as List?)
            ?.cast<String>() ??
        const <String>[];
    final data = _fullImages[currentImage.id];
    final isFav = widget.favoritesStore.isFavorite(currentImage.id);
    final isDl = _isWorkDownloaded();
    final cacheSource = _cacheSources[currentImage.id];

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: GestureDetector(
        onTap: () => _setOverlay(!_showOverlay),
        onVerticalDragEnd: _onVerticalFling,
        onHorizontalDragEnd: _onHorizontalFling,
        child: Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Center(child: _buildPage(currentImage, data)),
                // Page sidebar (right edge)
                if (pages.length > 1)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: _buildPageSidebar(pages),
                  ),
                if (_showOverlay) ...[
                  // Only the tags up here now. Getting out, where this is and
                  // what its address is are the toolbar's, which is showing
                  // just above (ADR 010 決定 7) — keeping a second set of them
                  // meant two of everything, and the two overlapped.
                  if (tags.isNotEmpty) _buildTagOverlay(tags),
                  _buildBottomBar(currentImage, isFav, isDl, cacheSource),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What is in the way of the page, if anything is. Null means there is a
  /// page to show, which is the only case the rest of [build] handles.
  Widget? _buildInterruption() {
    if (_isResolvingPages) {
      return _plainScreen(body: const Center(child: CircularProgressIndicator()));
    }

    if (_isDownloading) {
      return _plainScreen(
        onKeyEvent: _abandonDownloadOnEscape,
        body: Center(
          child: _downloadProgress != null
              ? _buildDownloadProgress()
              : const CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return _plainScreen(
        // The only one of the three with a way out of its own: the host's
        // toolbar is not over a viewer that never opened.
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: widget.onClose,
          ),
          title: const Text('エラー', style: TextStyle(color: Colors.white)),
        ),
        body: Center(
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }

    return null;
  }

  /// The three screens that are not a page: still working out what the pages
  /// are, a download in the way, and a work that would not open. Black, with
  /// the same pointer handling, and the keyboard as [_onKeyEvent] has it
  /// unless the screen means something else by a key.
  Widget _plainScreen({
    required Widget body,
    PreferredSizeWidget? appBar,
    FocusOnKeyEventCallback? onKeyEvent,
  }) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent ?? _onKeyEvent,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: appBar,
          body: body,
        ),
      ),
    );
  }

  /// Escape means "stop waiting for this download", not "leave the viewer" —
  /// which is what it means everywhere else, so nothing else is handled here.
  KeyEventResult _abandonDownloadOnEscape(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _isDownloading = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The window in device pixels: what a page is worth *making* at, for the
  /// one source that has to make it.
  static Size _displaySizePx(BuildContext context) {
    final media = MediaQuery.of(context);
    return media.size * media.devicePixelRatio;
  }

  /// The window's width in device pixels: what a page is worth decoding at.
  ///
  /// Only the width, since giving both dimensions to a decoder stretches the
  /// picture to fit them. A page taller than the window still decodes a little
  /// larger than it is drawn, which is a long way short of decoding it at
  /// whatever the scanner produced.
  static int _displayWidthPx(BuildContext context) {
    final media = MediaQuery.of(context);
    return (media.size.width * media.devicePixelRatio).round();
  }

  /// Whatever this page turns out to be: a film, something nothing can open,
  /// the picture itself, or the wait for it.
  Widget _buildPage(ImageSource currentImage, Uint8List? data) {
    if (_isVideo(currentImage)) {
      return ViewerVideoPage(
        key: ValueKey(currentImage.id),
        item: currentImage,
        registry: widget.registry,
        proxyServer: widget.proxyServer,
        // A video left part-way through comes back to black and its bar, not
        // to its own opening frame: the still would say the wrong thing about
        // where it is.
        poster: _resting ? null : _posterFor(currentImage),
        startAt: _videoAt,
        play: _autoplayNext || _playAsked,
        onPlayingChanged: (p) => _videoWasPlaying = p,
        onPlayer: _attachVideo,
      );
    }
    if (currentImage.metadata?['unsupported'] == true) {
      return _buildUnsupported(currentImage);
    }
    // Drawn here rather than fetched: already pixels, so nothing to decode.
    final drawn = _rendered[currentImage.id];
    if (drawn != null) {
      return _zoomed(RawImage(
        image: drawn,
        fit: BoxFit.contain,
        // The image is in device pixels; without this it would be laid out as
        // though those were logical ones.
        scale: MediaQuery.devicePixelRatioOf(context),
      ));
    }
    if (data != null) {
      return _zoomed(Image.memory(
        data,
        fit: BoxFit.contain,
        // Decoded at the width of the window rather than of the file
        // (ADR 012). A 3000x2000 scan is 24MB decoded, and four pages are
        // held ahead of this one; Flutter's image cache is 100MB.
        cacheWidth: _displayWidthPx(context),
      ));
    }
    return _buildUnreadable(currentImage) ??
        _buildLoadingIndicator(currentImage.id);
  }

  /// The page under the reader's pinch and drag.
  Widget _zoomed(Widget child) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translate(_offset.dx, _offset.dy) // ignore: deprecated_member_use
        ..scale(_scale), // ignore: deprecated_member_use
      child: child,
    );
  }

  /// A file the listing let through but nothing here can draw. Named, so it
  /// can be told from a page that is merely slow.
  Widget _buildUnsupported(ImageSource image) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.block, color: Colors.white38, size: 64),
        const SizedBox(height: 16),
        Text(
          image.name.split(') ').last,
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 8),
        const Text(
          'Unsupported format',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildTagOverlay(List<String> tags) {
    return Positioned(
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
          // Below whatever the host floats over us, so the two do not land on
          // top of each other.
          child: Padding(
            padding: EdgeInsets.only(top: widget.topInset),
            child: _buildTagBar(tags),
          ),
        ),
      ),
    );
  }

  void _onVerticalFling(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -300) {
      _nextPage();
    } else if (velocity > 300) {
      _prevPage();
    }
  }

  void _onHorizontalFling(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -500) {
      _nextItem(); // 左スワイプ → 次の作品
    } else if (velocity > 500) {
      _prevItem(); // 右スワイプ → 前の作品
    }
  }

  /// Everything about the item that is not the item: what it is called, what
  /// can be done to it, where the reader is in it. Video controls join the
  /// same bar rather than bringing their own (ADR 010 決定 8).
  Widget _buildBottomBar(
    ImageSource currentImage,
    bool isFav,
    bool isDl,
    CacheSource? cacheSource,
  ) {
    return Positioned(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?_videoBar(),
              Row(
                children: [
                  Expanded(child: _authorChip(currentImage)),
                  IconButton(
                    icon: Icon(
                      isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? Colors.redAccent : Colors.white,
                    ),
                    onPressed: () => _toggleFavorite(currentImage),
                    tooltip: 'お気に入り',
                  ),
                  IconButton(
                    icon: Icon(
                      isDl ? Icons.download_done : Icons.download,
                      color: isDl ? Colors.greenAccent : Colors.white,
                    ),
                    onPressed: () => _toggleDownload(currentImage),
                    tooltip: 'ダウンロード',
                  ),
                  Text(
                    _buildPositionText(),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  ?_cacheSourceIcon(cacheSource),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tap to follow the author, long-press to open them alongside — the same
  /// pair as everywhere else a place can be reached from (ADR 010 決定 6).
  Widget _authorChip(ImageSource currentImage) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showAuthor(currentImage, newTab: true),
        child: ActionChip(
          avatar: const Icon(Icons.person, size: 16, color: Colors.black54),
          label: Text(
            currentImage.metadata?['author'] as String? ?? '',
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => _showAuthor(currentImage),
          backgroundColor: Colors.white.withValues(alpha: 0.85),
          labelStyle: const TextStyle(color: Colors.black87, fontSize: 12),
          side: BorderSide.none,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  /// Where this page came from, when that is known: the network, or a cache
  /// that already had it.
  Widget? _cacheSourceIcon(CacheSource? cacheSource) {
    if (cacheSource == null) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Icon(
        cacheSource == CacheSource.network
            ? Icons.cloud_download
            : Icons.storage,
        color: Colors.white70,
        size: 16,
      ),
    );
  }

  Widget _buildPageSidebar(List<ImageSource> pages) {
    final active = _sidebarActive;
    return MouseRegion(
      onEnter: (_) => setState(() => _sidebarActive = true),
      onExit: (_) => setState(() => _sidebarActive = false),
      child: GestureDetector(
        onVerticalDragStart: (_) => setState(() => _sidebarActive = true),
        onVerticalDragEnd: (_) => setState(() => _sidebarActive = false),
        onVerticalDragUpdate: (details) {
          // A drag reports the whole way down, so most of what it says is
          // where we already are.
          final page = _pageAt(details.localPosition.dy, pages.length);
          if (page != _pageIndex) _goToPage(page);
        },
        onTapDown: (details) =>
            _goToPage(_pageAt(details.localPosition.dy, pages.length)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: active ? 40 : 6,
          color: active ? Colors.black26 : Colors.transparent,
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _sidebarMarker(constraints.maxHeight, pages.length, active),
          ),
        ),
      ),
    );
  }

  /// The page the sidebar is pointing at, [dy] down its height.
  int _pageAt(double dy, int pageCount) {
    final height = context.size?.height ?? 1;
    final ratio = (dy / height).clamp(0.0, 1.0);
    return (ratio * (pageCount - 1)).round();
  }

  /// A thumb at the reader's place: a tick on the edge normally, and the page
  /// number itself once the sidebar has been reached for.
  Widget _sidebarMarker(double totalHeight, int pageCount, bool active) {
    final top = pageCount > 1
        ? (_pageIndex / (pageCount - 1)) * (totalHeight - 24)
        : 0.0;
    if (!active) {
      return Stack(children: [
        Positioned(
          top: top,
          right: 0,
          child: Container(
            width: 4,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.white38,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ]);
    }
    return Stack(children: [
      Positioned(
        top: top,
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
    ]);
  }

  /// Position within the work list. The page number within the work (e.g.
  /// "1/10") is already shown in the top bar via the work name, so it is not
  /// repeated here.
  /// Where the reader is, in both senses: which page of this work, and which
  /// work of the list. Both live down here with the rest of the state, since
  /// neither is somewhere to go — the address names the work and stops there
  /// (ADR 010 決定 4).
  String _buildPositionText() {
    final pages = _pages;
    final within = pages != null && pages.length > 1
        ? '[${_pageIndex + 1}/${pages.length}]'
        : '';
    final among = widget.items.length > 1
        ? '[${widget.index + 1}/${widget.items.length}]'
        : '';
    return [within, among].where((s) => s.isNotEmpty).join(' ');
  }
}
