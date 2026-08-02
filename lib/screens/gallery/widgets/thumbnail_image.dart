import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../gallery_constants.dart';

/// A thumbnail, decoded at the size it is drawn (ADR 012).
///
/// Without [Image.cacheWidth] the bytes are decoded at whatever resolution
/// they were stored at, into Flutter's own image cache, to fill a tile a
/// fraction of the size. A Pixiv `square1200` is 5.76MB decoded and that cache
/// holds 100MB, so seventeen of them fill it — against forty tiles on a
/// screenful, which is how a scroll ends up decoding the same pictures over
/// and over.
///
/// The size does not depend on how wide the window is: a tile is sized from
/// the screen's shortest side, so this is one number per device.
class ThumbnailImage extends StatelessWidget {
  final Uint8List data;

  const ThumbnailImage(this.data, {super.key});

  @override
  Widget build(BuildContext context) => Image.memory(
        data,
        fit: BoxFit.cover,
        cacheWidth: galleryThumbnailPx(context),
      );
}
