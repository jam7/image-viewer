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
/// What differs per source is injected: the [appBar], the optional [header]
/// row above the grid, and [tileBuilder] for the tiles themselves. Which items
/// to show is the caller's too — the Pixiv screen filters by page count — so
/// [items] is passed in rather than read off the session.
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

  final PreferredSizeWidget appBar;

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
    required this.appBar,
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

  GallerySession get _session => widget.tab.current;

  @override
  void initState() {
    super.initState();
    _shown = widget.tab.current;
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

  @override
  void didUpdateWidget(GalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shown != widget.tab.current) _onSessionChanged();
  }

  /// The tab moved to a different entry: navigated, went back, or reloaded in
  /// place. Hand the thumbnails over, and fetch only if the new entry has never
  /// loaded — revisiting one from the history must not append another page.
  void _onSessionChanged() {
    _shown.detach();
    _shown = widget.tab.current;
    _error = null;
    _shown.attach();
    if (!_shown.hasLoaded) loadNextPage();
  }

  @override
  void deactivate() {
    _session.detach();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _session.attach();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Append the next page (the first one initially) and dispatch its thumbnail
  /// batch. A no-op once the source reports no more pages, so it is safe to
  /// call from the scroll trigger.
  Future<void> loadNextPage() async {
    if (!mounted || _isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await _session.loadNextPage();
      if (!mounted) return;
      setState(() => _isLoading = false);
      widget.onItemsChanged?.call();
      await _session.thumbnails.loadNextBatch();
      fillViewport();
    } catch (e, st) {
      _log.warning('page load failed: ${_session.sourceUri}', e, st);
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _onScroll() {
    if (_isLoading || !_session.hasMore) return;
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
      if (_session.hasMore) {
        loadNextPage();
      } else if (!_session.thumbnails.allDispatched) {
        _session.thumbnails.loadNextBatch();
      }
    });
  }

  /// Step back one history entry, or leave the screen if this is the first one.
  /// Every back affordance routes here.
  void goBack() {
    if (widget.tab.back()) {
      setState(_onSessionChanged);
      widget.onItemsChanged?.call();
      return;
    }
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
        if (!didPop) goBack();
      },
      child: GalleryKeyboardScrollable(
        focusNode: _focusNode,
        scrollController: _scrollController,
        onPop: goBack,
        child: Scaffold(
          appBar: widget.appBar,
          body: Column(
            children: [
              if (widget.header != null) widget.header!,
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              Expanded(
                child: GalleryGrid(
                  scrollController: _scrollController,
                  items: widget.items,
                  isLoading: _isLoading,
                  showTrailingLoader: _isLoading,
                  emptyMessage: widget.emptyMessage,
                  tileBuilder: _buildTile,
                  anchor: _session.anchor,
                  restoreKey: _session,
                  onAnchorChanged: (a) => _session.anchor = a,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context, int index) {
    final item = widget.items[index];
    // Painting a tile past what the loader has dispatched means the view has
    // scrolled ahead of the thumbnails; ask for the next batch.
    if (_session.needsBatchFor(item)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _session.thumbnails.loadNextBatch();
      });
    }
    return widget.tileBuilder(context, item, index);
  }
}
