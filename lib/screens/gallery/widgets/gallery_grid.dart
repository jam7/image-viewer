import 'package:flutter/material.dart';

import '../gallery_constants.dart';

/// Shared grid scaffold for the gallery screens: the empty / initial-loading
/// states plus the `Scrollbar` + `GridView` layout. Tile content differs per
/// screen (Pixiv badge vs SMB folder/video/archive icons), so it is delegated
/// to [tileBuilder]; load-more scheduling also stays with each screen.
class GalleryGrid extends StatelessWidget {
  final ScrollController scrollController;
  final int itemCount;
  final Widget Function(BuildContext context, int index) tileBuilder;

  /// Shown centered when there are no items and nothing is loading.
  final String emptyMessage;

  /// Show a centered spinner instead of [emptyMessage] while the first load
  /// is in flight (itemCount still 0).
  final bool isLoading;

  /// Append a trailing spinner cell for infinite-scroll "loading more".
  final bool showTrailingLoader;

  const GalleryGrid({
    super.key,
    required this.scrollController,
    required this.itemCount,
    required this.tileBuilder,
    required this.emptyMessage,
    this.isLoading = false,
    this.showTrailingLoader = false,
  });

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0 && isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (itemCount == 0) {
      return Center(child: Text(emptyMessage));
    }

    final count = itemCount + (showTrailingLoader ? 1 : 0);
    return Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: GridView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(4),
        gridDelegate: galleryGridDelegate,
        itemCount: count,
        itemBuilder: (context, index) {
          if (index >= itemCount) {
            return const Center(child: CircularProgressIndicator());
          }
          return tileBuilder(context, index);
        },
      ),
    );
  }
}
