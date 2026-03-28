import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _log = Logger('VideoThumbnail');

/// Captures video thumbnails using media_kit.
/// Reuses a single Player + VideoController across multiple captures.
/// Serializes captures to prevent concurrent Player.open conflicts.
/// Call [dispose] when no longer needed.
class VideoThumbnailService {
  Player? _player;
  Completer<void>? _lock;

  /// Capture a thumbnail from the given video URL at 3 seconds.
  /// Returns JPEG bytes, or null if capture fails.
  /// Serialized: concurrent calls wait for the previous capture to finish.
  Future<Uint8List?> capture(String url) async {
    // Wait for any in-progress capture
    while (_lock != null) {
      await _lock!.future;
    }
    _lock = Completer<void>();
    try {
      return await _captureImpl(url);
    } finally {
      final lock = _lock;
      _lock = null;
      lock?.complete();
    }
  }

  Future<Uint8List?> _captureImpl(String url) async {
    _ensurePlayer();
    final player = _player!;

    try {
      await player.open(Media(url, start: const Duration(seconds: 3)));
      await player.stream.position
          .firstWhere((p) => p >= const Duration(seconds: 2))
          .timeout(const Duration(seconds: 15));
      await Future.delayed(const Duration(milliseconds: 200));
      await player.pause();

      // Retry screenshot if null (frame buffer may not be ready yet)
      Uint8List? bytes;
      for (var attempt = 0; attempt < 5; attempt++) {
        bytes = await player.screenshot(format: 'image/jpeg');
        if (bytes != null) break;
        _log.info('screenshot null, retrying (${attempt + 1}/5)...');
        await Future.delayed(const Duration(milliseconds: 200));
      }

      await player.stop();
      return bytes;
    } catch (e, st) {
      _log.warning('capture failed: $e', e, st);
      return null;
    }
  }

  void _ensurePlayer() {
    if (_player == null) {
      _player = Player();
      // VideoController は Player.dispose() 時に内部的にクリーンアップされる
      VideoController(_player!);
      _player!.setVolume(0);
    }
  }

  Future<void> dispose() async {
    if (_player != null) {
      await _player!.dispose();
      _player = null;
    }
  }
}
