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
  /// Width the grid was last laid out at. A change means a resize/rotation.
  double? _laidOutWidth;

  /// Last anchor computed from a real scroll position. Held here rather than
  /// read back from [GalleryGrid.anchor] so a resize uses the position as of
  /// the resize, even if the parent has not rebuilt since the user scrolled.
  ScrollAnchor? _recorded;

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
    if (oldWidget.restoreKey != widget.restoreKey) _restoreForNewList();
  }

  /// Now showing a different place. The scroll controller is shared, so it
  /// still holds the previous place's offset; put it where this one left off,
  /// or at the top if it has never been scrolled.
  void _restoreForNewList() {
    _recorded = null;
    final anchor = widget.anchor;
    final width = _laidOutWidth;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.scrollController.hasClients) return;
      if (anchor == null || width == null) {
        widget.scrollController.jumpTo(0);
      } else {
        _applyAnchor(anchor, width);
      }
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
    final width = _laidOutWidth;
    if (width == null || widget.items.isEmpty) return;
    if (!widget.scrollController.hasClients) return;

    final stride = galleryRowStride(width);
    if (stride <= 0) return;
    // Overscroll goes negative; treat it as the top.
    final pixels = widget.scrollController.position.pixels.clamp(
        0.0, double.maxFinite);
    final row = (pixels / stride).floor();
    final index = row * galleryCrossAxisCount;
    if (index >= widget.items.length) return;

    final anchor =
        ScrollAnchor(widget.items[index].id, (pixels - row * stride) / stride);
    if (anchor == _recorded) return;
    _recorded = anchor;
    widget.onAnchorChanged?.call(anchor);
  }

  /// Put [anchor]'s item back at the top-left under the current layout.
  void _applyAnchor(ScrollAnchor anchor, double width) {
    if (!widget.scrollController.hasClients) return;
    final index = widget.items.indexWhere((i) => i.id == anchor.itemId);
    if (index < 0) return; // filtered out or not loaded yet: leave the view be

    final stride = galleryRowStride(width);
    final row = index ~/ galleryCrossAxisCount;
    final target = (row + anchor.rowFraction) * stride;
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

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (_laidOutWidth != width) {
        final firstLayout = _laidOutWidth == null;
        _laidOutWidth = width;
        // On first layout restore what the caller handed us; on a resize keep
        // the item the user was looking at. Deferred because the scroll
        // position's extents are only known once this frame has laid out.
        final anchor = firstLayout ? widget.anchor : _recorded;
        if (anchor != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _applyAnchor(anchor, width);
          });
        }
      }
      return _buildGrid();
    });
  }

  Widget _buildGrid() {
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
        gridDelegate: galleryGridDelegate,
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
