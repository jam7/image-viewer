import 'package:flutter/material.dart';

import '../../../models/image_source.dart';
import '../../../widgets/thumbnail_result.dart';
import '../gallery_constants.dart';
import '../gallery_session.dart';

/// One tile's thumbnail, and only that tile (ADR 011 段階 3).
///
/// Asks for the thumbnail by being built — that is the whole of the pull —
/// and rebuilds itself, alone, when the answer arrives. What it replaced was a
/// repaint of the entire grid per thumbnail: filling a screenful meant
/// rebuilding every visible tile a hundred times over, on the thread trying to
/// draw the scroll, which is what made a list stutter exactly while it was
/// worth looking at.
class ThumbnailOf extends StatefulWidget {
  final GallerySession session;
  final ImageSource item;

  /// Draws the tile from what is held: null while there is no answer yet.
  final Widget Function(BuildContext context, ThumbnailResult? thumbnail)
  builder;

  const ThumbnailOf({
    super.key,
    required this.session,
    required this.item,
    required this.builder,
  });

  @override
  State<ThumbnailOf> createState() => _ThumbnailOfState();
}

class _ThumbnailOfState extends State<ThumbnailOf> {
  @override
  void initState() {
    super.initState();
    widget.session.watchThumbnail(widget.item.id, _changed);
  }

  @override
  void didUpdateWidget(ThumbnailOf old) {
    super.didUpdateWidget(old);
    // A grid reuses its tiles for other items as it scrolls.
    if (old.item.id == widget.item.id && old.session == widget.session) return;
    old.session.unwatchThumbnail(old.item.id, _changed);
    widget.session.watchThumbnail(widget.item.id, _changed);
  }

  @override
  void dispose() {
    widget.session.unwatchThumbnail(widget.item.id, _changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Two things, said in two lines: what there is to draw, and that this tile
    // wants one. Being painted is the whole of the asking — there is no other
    // trigger to forget to wire up, which is how the retry this replaced came
    // to stop working without anyone noticing.
    final thumbnail = widget.session.thumbnailFor(widget.item);
    widget.session.wantThumbnail(widget.item,
        targetPx: galleryThumbnailPx(context));
    return widget.builder(context, thumbnail);
  }
}
