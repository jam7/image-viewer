import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../../models/image_source.dart';
import '../system_back.dart';
import '../gallery_session.dart';
import '../gallery_tab.dart';
import 'gallery_chrome.dart';
import 'gallery_grid.dart';
import 'gallery_keyboard_scrollable.dart';

final _log = Logger('GalleryView');

/// Everything a gallery screen does that is not about a particular source:
/// drive [GallerySession] page loads, keep thumbnail batches ahead of the
/// view, hold the scroll and focus, release and restore thumbnails as the
/// screen comes and goes, and render the scaffold around the grid.
///
/// This is the content of a tab, not the frame around it: the app bar belongs
/// to the host, which keeps one across every tab. What differs per source is
/// injected: [tileBuilder] for the tiles, and nothing else. What to show is
/// the session's own `visibleItems` — the list after any display-only filter —
/// since the viewer walks the same list looking for neighbours (ADR 010), and
/// a narrowing only the grid knew about would not hold there. Nothing is
/// injected above the grid either: every control that used to sit there is in
/// the toolbar now (ADR 009).
///
/// Scrolling drives one path (ADR 007 決定 3): approaching the end asks the
/// session for another page, and painting a tile past the dispatched range asks
/// the loader for another thumbnail batch. A finite source simply reports no
/// more pages, so the first half stops firing after its one page.
///
/// Going back means going back in [tab]'s history, and nothing else: at the
/// first entry it does nothing at all. Closing a tab is the chip's `x`, never a
/// side effect of navigating (ADR 009 追記) — history is not recoverable, and a
/// double-tapped back button should not be able to destroy it. Every way of
/// asking — Escape, Backspace, the mouse back button, a rightward swipe — goes
/// through [goBack]; the system gesture goes through the [PopScope] in [build],
/// which leaves the app once there is no history left.
class GalleryView extends StatefulWidget {
  /// The tab being shown. Its current entry is the place on screen.
  final GalleryTab tab;

  final Widget Function(BuildContext context, ImageSource item, int index)
      tileBuilder;

  /// Shown when the list is empty and nothing is loading.
  final String emptyMessage;

  /// Called when what should be on screen has changed under the caller's feet —
  /// a page was appended, or a back step moved the tab to another entry. The
  /// caller derives [items] and the [appBar] title from the tab, so it has to
  /// rebuild too; this view's own setState does not reach them.
  final VoidCallback? onItemsChanged;

  const GalleryView({
    super.key,
    required this.tab,
    required this.tileBuilder,
    required this.emptyMessage,
    this.onItemsChanged,
  });

  @override
  State<GalleryView> createState() => GalleryViewState();
}

/// Public so a screen can drive the view it owns (e.g. re-read the current
/// page). Reach it with a `GlobalKey<GalleryViewState>`.
class GalleryViewState extends State<GalleryView> {
  /// How close to the end counts as "about to run out" (logical pixels).
  static const _loadMoreMargin = 200.0;

  final _scrollController = ScrollController();

  /// Reading forward folds the header away (ADR 009). The rule is per view, so
  /// each tab makes up its own mind and none of them fight over it.
  final _chromeRule = ChromeScrollRule();
  ValueNotifier<bool>? _chrome;
  final _focusNode = FocusNode();
  bool _isLoading = false;
  String? _error;

  /// The entry currently on screen. Compared against the tab's current entry to
  /// notice a navigation, which the tab performs without telling us.
  late GallerySession _shown;

  /// How many items were on screen last build, to notice a narrowing that
  /// happened somewhere else — the page-count filter lives on the toolbar.
  int _shownCount = 0;

  @override
  void initState() {
    super.initState();
    _shown = widget.tab.current;
    _shown.onChanged = _repaint;
    _log.info('view for tab=${widget.tab.id} '
        'index=${widget.tab.index}/${widget.tab.history.length} '
        'at=${_shown.sourceUri}');
    _scrollController.addListener(_onScroll);
    _startChromeRule();
    // Switching tabs builds a fresh view over a session that may already hold
    // its items; fetching again would append a duplicate page. Same rule as
    // [_onSessionChanged], which handles the moves within one view.
    if (_shown.hasLoaded) {
      _shown.attach();
    } else {
      loadNextPage();
    }
  }

  /// Repaint for something the session did — a thumbnail arriving. Installed on
  /// whichever session is on screen, so it does not matter who created it.
  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome = GalleryChrome.maybeOf(context);
  }

  /// Tell the fold rule where this list starts, once there is a viewport to
  /// ask. Until it knows, the first movement would be spent finding out.
  ///
  /// There is usually no viewport on the frame a place opens — a list still
  /// loading is a spinner, with nothing to scroll — so this waits for one.
  /// Waiting costs nothing: a post-frame callback does not ask for a frame, so
  /// on a place that never gets a grid this simply stops being asked.
  void _startChromeRule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        _startChromeRule();
        return;
      }
      _chromeRule.start(_scrollController.position.pixels);
      _chrome?.value = true;
    });
  }

  @override
  void didUpdateWidget(GalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shown != widget.tab.current) {
      _onSessionChanged();
      return;
    }
    // Same place, fewer items: the toolbar narrowed the list. A grid that ends
    // up shorter than the viewport has nothing left to ask for the next page.
    if (_shownCount == _shown.visibleItems.length) return;
    _shownCount = _shown.visibleItems.length;
    fillViewport();
  }

  /// The tab moved to a different entry: navigated, went back, or reloaded in
  /// place. Hand the thumbnails over, and fetch only if the new entry has never
  /// loaded — revisiting one from the history must not append another page.
  void _onSessionChanged() {
    _shown.onChanged = null;
    _shown.detach();
    _shown = widget.tab.current;
    _shown.onChanged = _repaint;
    _error = null;
    // A load still running for the place we just left no longer owns this flag;
    // leaving it set would block the new entry from ever loading, and leave a
    // spinner up over content that is already here.
    _isLoading = false;
    _shownCount = _shown.visibleItems.length;
    _shown.attach();
    if (!_shown.hasLoaded) loadNextPage();
    // A different place, at a different height: measure the fold from there.
    _startChromeRule();
  }

  // These go through [_shown] rather than the tab: a closed tab has already
  // disposed its history, so asking it for a current entry throws just as the
  // view is being torn down.
  @override
  void deactivate() {
    _shown.detach();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _shown.attach();
  }

  @override
  void dispose() {
    // Only if it is still ours. Navigating across sources within one tab swaps
    // the whole body (fav:// to pixiv:// picks a different widget), and Flutter
    // builds the replacement before unmounting this one — so the session may
    // already be reporting to the new view, and clearing it here would leave
    // that view without repaints as its thumbnails arrive.
    if (_shown.onChanged == _repaint) _shown.onChanged = null;
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Append the next page (the first one initially) and dispatch its thumbnail
  /// batch. A no-op once the source reports no more pages, so it is safe to
  /// call from the scroll trigger.
  Future<void> loadNextPage() async {
    if (!mounted || _isLoading) return;
    // Pinned for the whole call: the tab can move somewhere else mid-fetch, and
    // a slow page (Pixiv goes through the WebView) must not then land its
    // results, its spinner or its error on whatever is on screen by then.
    final session = _shown;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await session.loadNextPage();
      if (!mounted || session != _shown) return;
      setState(() => _isLoading = false);
      widget.onItemsChanged?.call();
      await session.thumbnails.loadNextBatch();
      if (!mounted || session != _shown) return;
      fillViewport();
    } catch (e, st) {
      _log.warning('page load failed: ${session.sourceUri}', e, st);
      if (!mounted || session != _shown) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _onScroll() {
    final position = _scrollController.position;
    final chrome = _chromeRule.update(position.pixels, atTop: position.pixels <= 0);
    if (chrome != null) _chrome?.value = chrome;
    if (_isLoading || !_shown.hasMore) return;
    if (position.pixels >= position.maxScrollExtent - _loadMoreMargin) {
      loadNextPage();
    }
  }

  /// Nothing to scroll means the scroll trigger can never fire, so keep pulling
  /// until the view has content to scroll: another page if there is one,
  /// otherwise the next thumbnail batch.
  ///
  /// Also worth calling after the caller narrows [GalleryView.items] with a
  /// display-only filter, which can leave too little to scroll.
  void fillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent > 0) return;
      if (_shown.hasMore) {
        loadNextPage();
      } else if (!_shown.thumbnails.allDispatched) {
        _shown.thumbnails.loadNextBatch();
      }
    });
  }

  /// Step back one history entry. At the first entry it does nothing: the tab
  /// stays, its history stays, and leaving is the system gesture's business
  /// (see the [PopScope] in [build]).
  void goBack() {
    if (widget.tab.back()) _afterStep();
  }

  /// Catch up with a move the tab made without us — the entry changed, so the
  /// view rebinds and the caller re-derives its items and title.
  void _afterStep() {
    setState(_onSessionChanged);
    widget.onItemsChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Always ours, even at the first entry, because letting the route pop is
      // finish(): the activity dies and every tab goes with it. Leaving is
      // still what happens there -- just as a move to the background, so
      // coming back is instant and nothing is lost.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleSystemBack(widget.tab, _afterStep);
      },
      child: GalleryKeyboardScrollable(
        focusNode: _focusNode,
        scrollController: _scrollController,
        onPop: goBack,
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: GalleryGrid(
                scrollController: _scrollController,
                items: _shown.visibleItems,
                isLoading: _isLoading,
                showTrailingLoader: _isLoading,
                emptyMessage: widget.emptyMessage,
                tileBuilder: _buildTile,
                anchor: _shown.anchor,
                restoreKey: _shown,
                onAnchorChanged: (a) => _shown.anchor = a,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context, int index) {
    final item = _shown.visibleItems[index];
    // Painting a tile past what the loader has dispatched means the view has
    // scrolled ahead of the thumbnails; ask for the next batch.
    if (_shown.needsBatchFor(item)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shown.thumbnails.loadNextBatch();
      });
    }
    return widget.tileBuilder(context, item, index);
  }
}
