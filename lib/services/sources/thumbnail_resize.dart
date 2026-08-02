import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:logging/logging.dart';

final _log = Logger('ThumbnailResize');

/// Shrink [data] so that its long edge is at most [targetPx], as PNG bytes.
/// Returns [data] unchanged when it is already no larger than that.
///
/// The question is asked in pixels (ADR 012). It used to be asked in bytes —
/// anything under 400KB was passed through — which is not the same question:
/// a 300KB JPEG is routinely 3000x2000, and it is the pixels that are decoded
/// into memory to fill a tile a fraction of the size. The byte rule was really
/// working around "a small JPEG re-encoded as PNG gets bigger", and shrinking
/// to the tile makes that moot: at a couple of hundred pixels a PNG is small
/// whatever it started as.
///
/// The size is read from the header rather than by decoding, so a picture that
/// is already small costs nothing but the read.
///
/// Bytes that are not a picture at all are handed back untouched: shrinking is
/// this function's job and judging is not. Whatever they are, they reach the
/// tile as they would have before, and fail to draw there.
/// Turn one raw BGRA frame into thumbnail bytes: long edge at most
/// [targetPx], as PNG. Returns null if the pixels cannot be read.
///
/// This is [shrinkToFit] for pixels that were never encoded — a video frame
/// out of mpv. Same engine decode-with-target trick, same PNG at tile size;
/// the only difference is that the descriptor is built from raw pixels
/// instead of parsed out of a header.
///
/// mpv pads its rows sometimes, so the row length is taken from the buffer
/// ([height] rows is all it holds) rather than assumed to be `width * 4`.
Future<Uint8List?> shrinkRawFrame(
    Uint8List bgra, int width, int height, int targetPx) async {
  final rowBytes = bgra.length ~/ height;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bgra);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    rowBytes: rowBytes,
    pixelFormat: ui.PixelFormat.bgra8888,
  );
  final longEdge = width > height ? width : height;
  final scale = longEdge > targetPx ? targetPx / longEdge : 1.0;
  final codec = await descriptor.instantiateCodec(
    targetWidth: (width * scale).round(),
    targetHeight: (height * scale).round(),
  );
  // Same order as shrinkToFit below: the buffer goes, the descriptor stays.
  buffer.dispose();
  final frame = await codec.getNextFrame();
  try {
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) {
      _log.warning('could not encode a ${width}x$height frame');
      return null;
    }
    return png.buffer.asUint8List();
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

Future<Uint8List> shrinkToFit(Uint8List data, int targetPx) async {
  final ui.ImmutableBuffer buffer;
  final ui.ImageDescriptor descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(data);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
  } catch (e, st) {
    _log.warning('cannot read the size of ${data.length} bytes', e, st);
    return data;
  }
  final width = descriptor.width;
  final height = descriptor.height;
  final longEdge = width > height ? width : height;

  if (longEdge <= targetPx) {
    buffer.dispose();
    return data;
  }

  final scale = targetPx / longEdge;
  final codec = await descriptor.instantiateCodec(
    targetWidth: (width * scale).round(),
    targetHeight: (height * scale).round(),
  );
  // The buffer goes and the descriptor stays, which is the order the framework
  // uses in instantiateImageCodecWithSize and not the obvious one. Releasing
  // the descriptor here instead segfaults the decode thread: the codec is
  // still reading through it, and getNextFrame has not been awaited yet.
  buffer.dispose();
  final frame = await codec.getNextFrame();
  try {
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) {
      _log.warning('could not encode a ${width}x$height thumbnail');
      return data;
    }
    _log.info('thumbnail ${width}x$height -> '
        '${frame.image.width}x${frame.image.height} '
        '(${data.length ~/ 1024}KB -> ${png.lengthInBytes ~/ 1024}KB)');
    return png.buffer.asUint8List();
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}
