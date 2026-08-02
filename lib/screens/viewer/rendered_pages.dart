import 'dart:ui' as ui;

/// The pages the app drew itself, held until they are not wanted.
///
/// A PDF page is drawing instructions; somebody has to turn them into pixels,
/// and the result is a [ui.Image] rather than a file (ADR 012 の続き). Keeping
/// it as an image is what lets a page turn skip the encode — 366ms of PNG on
/// this device — and stops the cache filling with pictures that can be redrawn
/// in 84ms.
///
/// The reason this is a class and not a `Map` is disposal. Bytes are collected
/// when nothing points at them; a [ui.Image] holds memory the collector does
/// not manage, and dropping one without disposing it leaks quietly — the app
/// works, and then does not, a long way from the mistake. So there is no way
/// to take an image out of here: **every path that removes one disposes it**,
/// and the viewer never calls dispose itself.
class RenderedPages {
  final Map<String, ui.Image> _held = {};

  int get length => _held.length;

  ui.Image? operator [](String id) => _held[id];

  bool contains(String id) => _held.containsKey(id);

  /// Hold [image] for [id], disposing whatever was there before. The one that
  /// arrives is the newer render — a resize, or a second attempt.
  void put(String id, ui.Image image) {
    final old = _held[id];
    if (identical(old, image)) return;
    old?.dispose();
    _held[id] = image;
  }

  /// Keep the pages near the reader and let go of the rest.
  void keepOnly(Set<String> ids) {
    _held.removeWhere((id, image) {
      if (ids.contains(id)) return false;
      image.dispose();
      return true;
    });
  }

  void clear() {
    for (final image in _held.values) {
      image.dispose();
    }
    _held.clear();
  }
}
