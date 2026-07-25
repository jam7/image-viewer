import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../../models/image_source.dart';
import '../gallery_session.dart';
import '../gallery_tab.dart';
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
/// injected — the optional [header] row above the grid, and [tileBuilder] for
/// the tiles. Which items to show is the caller's too — the Pixiv screen
/// filters by page count — so [items] is passed in rather than read off the
/// session.
///
/// Scrolling drives one path (ADR 007 決定 3): approaching the end asks the
/// session for another page, and painting a tile past the dispatched range asks
/// the loader for another thumbnail batch. A finite source simply reports no
/// more pages, so the first half stops firing after its one page.
///
/// Going back means going back in [tab]'s history; only at its first entry does
/// it leave the screen. Every way of asking — Escape, Backspace, the mouse back
/// button, a rightward swipe, and the system back gesture — goes through
/// [goBack] so they cannot drift apart (ADR 008 決定 3).
class GalleryView extends StatefulWidget {
  /// The tab being shown. Its current entry is the place on screen.
  final GalleryTab tab;

  /// Items to show, in display order — the session's loaded list after any
  /// display-only filter the caller applies.
  final List<ImageSource> items;

  final Widget Function(BuildContext context, ImageSource item, int index)
      tileBuilder;

  /// Shown when the list is empty and nothing is loading.
  final String emptyMessage;

  /// Optional row between the app bar and the grid (search / filter controls).
  final Widget? header;

  /// Called when what should be on screen has changed under the caller's feet —
  /// a page was appended, or a back step moved the tab to another entry. The
  /// caller derives [items] and the [appBar] title from the tab, so it has to
  /// rebuild too; this view's own setState does not reach them.
  final VoidCallback? onItemsChanged;

  const GalleryView({
    super.key,
    required this.tab,
    required this.items,
    required this.tileBuilder,
    required this.emptyMessage,
    this.header,
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
  final _focusNode = FocusNode();
  bool _isLoading = false;
  String? _error;
  bool _isPopping = false;

  /// The entry currently on screen. Compared against the tab's current entry to
  /// notice a navigation, which the tab performs without telling us.
  late GallerySession _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.tab.current;
    _shown.onChanged = _repaint;
    _log.info('view for tab=${widget.tab.id} '
        'index=${widget.tab.index}/${widget.tab.history.length} '
        'at=${_shown.sourceUri}');
    _scrollController.addListener(_onScroll);
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
  void didUpdateWidget(GalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shown != widget.tab.current) _onSessionChanged();
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
    _shown.attach();
    if (!_shown.hasLoaded) loadNextPage();
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
    if (_isLoading || !_shown.hasMore) return;
    final position = _scrollController.position;
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

  /// Step back one history entry, or leave the screen if this is the first one.
  /// Every back affordance routes here.
  void goBack() {
    _log.info('goBack: tab=${widget.tab.id} '
        'index=${widget.tab.index}/${widget.tab.history.length} '
        'canGoBack=${widget.tab.canGoBack}');
    if (widget.tab.back()) {
      setState(_onSessionChanged);
      widget.onItemsChanged?.call();
      _log.info('goBack: stepped to ${_shown.sourceUri}');
      return;
    }
    _log.info('goBack: first entry, leaving the gallery');
    // Guard against multiple pop calls in the same frame (e.g. ESC key and
    // mouse back button firing simultaneously).
    if (_isPopping) return;
    _isPopping = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Let the system back gesture through only when there is no history left
      // to walk; otherwise handle it here like every other back affordance.
      canPop: !widget.tab.canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        _log.info('onPopInvoked: didPop=$didPop tab=${widget.tab.id} '
            'canGoBack=${widget.tab.canGoBack}');
        if (!didPop) goBack();
      },
      child: GalleryKeyboardScrollable(
        focusNode: _focusNode,
        scrollController: _scrollController,
        onPop: goBack,
        child: Column(
          children: [
            if (widget.header != null) widget.header!,
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: GalleryGrid(
                scrollController: _scrollController,
                items: widget.items,
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
    final item = widget.items[index];
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
