import 'package:flutter/material.dart';

import '../../../models/image_source.dart';
import '../gallery_constants.dart';
import '../scroll_anchor.dart';

/// Shared grid scaffold for the gallery screens: the empty / initial-loading
/// states plus the `Scrollbar` + `GridView` layout. Tile content differs per
/// screen (Pixiv badge vs SMB folder/video/archive icons), so it is delegated
/// to [tileBuilder]; load-more scheduling also stays with each screen.
///
/// Also keeps the view's place by item rather than by pixel offset (see
/// [ScrollAnchor]): it reports the top-left item as the user scrolls, and puts
/// the view back where it belongs whenever the position would otherwise be
/// wrong — on first layout, when the viewport width changes (so a rotation does
/// not jump the view by tens of items), and when [restoreKey] says the grid has
/// switched to a different place behind the same scroll controller.
class GalleryGrid extends StatefulWidget {
  final ScrollController scrollController;

  /// Items in display order. Their ids anchor the scroll position, so this is
  /// the list the screen actually shows (after any display-only filter).
  final List<ImageSource> items;
  final Widget Function(BuildContext context, int index) tileBuilder;

  /// Shown centered when there are no items and nothing is loading.
  final String emptyMessage;

  /// Show a centered spinner instead of [emptyMessage] while the first load
  /// is in flight (itemCount still 0).
  final bool isLoading;

  /// Append a trailing spinner cell for infinite-scroll "loading more".
  final bool showTrailingLoader;

  /// Where to scroll to when [restoreKey] changes (and on first layout). Null
  /// means start at the top.
  final ScrollAnchor? anchor;

  /// Identifies whose list this is. When it changes the grid is showing a
  /// different place through the same scroll controller, so the position has to
  /// be taken from [anchor] rather than left where the previous place put it.
  final Object? restoreKey;

  /// Reports the top-left item as the user scrolls, for the caller to store.
  /// Called on scroll frames, so it must not trigger a rebuild.
  final void Function(ScrollAnchor anchor)? onAnchorChanged;

  const GalleryGrid({
    super.key,
    required this.scrollController,
    required this.items,
    required this.tileBuilder,
    required this.emptyMessage,
    this.isLoading = false,
    this.showTrailingLoader = false,
    this.anchor,
    this.restoreKey,
    this.onAnchorChanged,
  });

  @override
  State<GalleryGrid> createState() => _GalleryGridState();
}

class _GalleryGridState extends State<GalleryGrid> {
  /// What the grid was last laid out with. A change means a resize/rotation.
  /// Held rather than recomputed because the scroll listener runs between
  /// builds and has to convert pixels to rows with the layout on screen.
  GalleryLayout? _layout;

  /// Last anchor computed from a real scroll position. Held here rather than
  /// read back from [GalleryGrid.anchor] so a resize uses the position as of
  /// the resize, even if the parent has not rebuilt since the user scrolled.
  ScrollAnchor? _recorded;

  /// A restore that has not found its item yet. A place being re-read installs
  /// an empty list and fills it a page later, so the restore is asked for while
  /// there is nothing to aim at. It waits here for the first page instead of
  /// being dropped — that is what sent the favorites list back to the top on
  /// every return from the viewer.
  ScrollAnchor? _pendingRestore;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_recordAnchor);
  }

  @override
  void didUpdateWidget(GalleryGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_recordAnchor);
      widget.scrollController.addListener(_recordAnchor);
    }
    if (oldWidget.restoreKey != widget.restoreKey) {
      _restoreForNewList();
    } else if (_pendingRestore != null) {
      // Not "did items change": a session hands out the same growing list every
      // build, so oldWidget.items and widget.items are one object and any
      // before/after comparison of them is a comparison with itself.
      _runPendingRestore();
    }
  }

  /// Now showing a different place. The scroll controller is shared, so it
  /// still holds the previous place's offset; put it where this one left off,
  /// or at the top if it has never been scrolled.
  void _restoreForNewList() {
    _recorded = null;
    _pendingRestore = null;
    final anchor = widget.anchor;
    if (anchor == null || _layout == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.scrollController.hasClients) return;
        widget.scrollController.jumpTo(0);
      });
      return;
    }
    _pendingRestore = anchor;
    _runPendingRestore();
  }

  /// Apply the waiting restore, if the list has anything in it yet.
  ///
  /// The first page to arrive is the only chance taken: the item may have been
  /// un-starred, or sit on a page nobody has asked for, and retrying on every
  /// later page would yank the view back under a reader who has since scrolled.
  void _runPendingRestore() {
    final anchor = _pendingRestore;
    if (anchor == null || widget.items.isEmpty) return;
    _pendingRestore = null;
    final layout = _layout;
    if (layout == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyAnchor(anchor, layout);
    });
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_recordAnchor);
    super.dispose();
  }

  /// Translate the current pixel offset into "which item is at the top-left,
  /// and how far past its row are we".
  void _recordAnchor() {
    final layout = _layout;
    if (layout == null || widget.items.isEmpty) return;
    if (!widget.scrollController.hasClients) return;

    final stride = layout.rowStride;
    if (stride <= 0) return;
    // Overscroll goes negative; treat it as the top.
    final pixels = widget.scrollController.position.pixels.clamp(
        0.0, double.maxFinite);
    final row = (pixels / stride).floor();
    final index = row * layout.columns;
    if (index >= widget.items.length) return;

    final anchor =
        ScrollAnchor(widget.items[index].id, (pixels - row * stride) / stride);
    if (anchor == _recorded) return;
    _recorded = anchor;
    widget.onAnchorChanged?.call(anchor);
  }

  /// Put [anchor]'s item back at the top-left under [layout].
  ///
  /// The anchor names an item, not a row, so it survives being recorded under
  /// one layout and applied under another — which is the whole point, since a
  /// rotation changes both the column count and the stride.
  void _applyAnchor(ScrollAnchor anchor, GalleryLayout layout) {
    if (!widget.scrollController.hasClients) return;
    final index = widget.items.indexWhere((i) => i.id == anchor.itemId);
    if (index < 0) return; // filtered out or not loaded yet: leave the view be

    final row = index ~/ layout.columns;
    final target = (row + anchor.rowFraction) * layout.rowStride;
    final position = widget.scrollController.position;
    widget.scrollController
        .jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty && widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.items.isEmpty) {
      return Center(child: Text(widget.emptyMessage));
    }

    final media = MediaQuery.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final layout = GalleryLayout.of(
          constraints.maxWidth, media.size, media.devicePixelRatio);
      if (_layout != layout) {
        final firstLayout = _layout == null;
        _layout = layout;
        // On first layout restore what the caller handed us; on a resize keep
        // the item the user was looking at. Deferred because the scroll
        // position's extents are only known once this frame has laid out.
        final anchor = firstLayout ? widget.anchor : _recorded;
        if (anchor != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _applyAnchor(anchor, layout);
          });
        }
      }
      return _buildGrid(layout);
    });
  }

  Widget _buildGrid(GalleryLayout layout) {
    final itemCount = widget.items.length;
    final count = itemCount + (widget.showTrailingLoader ? 1 : 0);
    return Scrollbar(
      controller: widget.scrollController,
      thumbVisibility: true,
      child: GridView.builder(
        controller: widget.scrollController,
        // Claim vertical drags even with nothing to scroll. The default physics
        // refuse them once the content fits, which lets a slightly diagonal
        // vertical flick reach the swipe-back gesture wrapped around the grid
        // and pop the screen. Short lists also get the same overscroll feedback
        // as long ones this way.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(galleryPadding),
        gridDelegate: layout.gridDelegate,
        itemCount: count,
        itemBuilder: (context, index) {
          if (index >= itemCount) {
            return const Center(child: CircularProgressIndicator());
          }
          return widget.tileBuilder(context, index);
        },
      ),
    );
  }
}
