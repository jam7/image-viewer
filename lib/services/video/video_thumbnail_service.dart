import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _log = Logger('VideoThumbnail');

/// One decoded frame, as mpv hands it over: full-size BGRA pixels.
///
/// Raw on purpose. media_kit's `format: 'image/jpeg'` walks the frame one
/// pixel at a time through package:image and then encodes it in pure Dart at
/// full resolution — the encoder alone measures ~2.3us per pixel on the
/// tablet, which is seconds for a 1080p frame, all spent on a picture that is
/// about to be shrunk to a tile. The caller shrinks these pixels in the
/// engine instead (`shrinkRawFrame`).
typedef CapturedFrame = ({Uint8List bgra, int width, int height});

/// Captures video thumbnails using media_kit.
/// Reuses a single Player + VideoController across multiple captures.
/// Serializes captures to prevent concurrent Player.open conflicts.
/// Call [dispose] when no longer needed.
class VideoThumbnailService {
  Player? _player;
  Completer<void>? _lock;

  /// Capture one frame from the given video URL at 3 seconds.
  /// Returns the raw frame, or null if capture fails.
  /// Serialized: concurrent calls wait for the previous capture to finish.
  Future<CapturedFrame?> capture(String url) async {
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

  Future<CapturedFrame?> _captureImpl(String url) async {
    _ensurePlayer();
    final player = _player!;

    try {
      // Opened paused: mpv seeks to `start` and decodes that one frame for
      // display, which is all a thumbnail needs. Playing (the old way) meant
      // waiting for the position to pass 2s, and seeks snap to keyframes —
      // when one landed early, those two seconds passed in real time, audio
      // decode and all.
      await player.open(
        Media(url, start: const Duration(seconds: 3)),
        play: false,
      );

      // The frame's own size, needed to read the raw pixels. It arrives when
      // the track is demuxed; open() resets it first, so this never sees the
      // previous video's answer.
      final params = await player.stream.videoParams
          .firstWhere((p) => (p.w ?? 0) > 0 && (p.h ?? 0) > 0)
          .timeout(const Duration(seconds: 15));

      // Demux said what the frame will be; the decoder may not have put it
      // up yet, and there is no event for that — hence polling.
      Uint8List? bytes;
      for (var attempt = 0; attempt < 10; attempt++) {
        bytes = await player.screenshot(format: null);
        if (bytes != null) break;
        _log.info('no frame yet, retrying (${attempt + 1}/10)...');
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (_player != null) await player.stop();
      if (bytes == null) return null;
      return (bgra: bytes, width: params.w!, height: params.h!);
    } catch (e, st) {
      if (_player == null) {
        // Player was externally disposed (e.g. video playback started)
        _log.info('capture cancelled');
      } else {
        _log.warning('capture failed: $e', e, st);
      }
      return null;
    }
  }

  void _ensurePlayer() {
    if (_player == null) {
      final player = Player();
      // VideoController は Player.dispose() 時に内部的にクリーンアップされる
      VideoController(player);
      final platform = player.platform;
      if (platform is NativePlayer) {
        // No audio at all. The volume was already 0, but the sound was still
        // being decoded — and, over the SMB proxy, still being downloaded.
        unawaited(platform.setProperty('aid', 'no'));
        // Keyframe seek. mpv's --start is a precise seek by default, which
        // decodes and discards everything from the previous keyframe to the
        // 3s mark — measured at 1.5-2s of CPU per video on the tablet, and
        // the one capture that needed more than the retry window fell off it.
        // A thumbnail does not care that the frame is exactly at 3s; the
        // nearest keyframe before it arrives at once.
        unawaited(platform.setProperty('hr-seek', 'no'));
      }
      player.setVolume(0);
      _player = player;
    }
  }

  Future<void> dispose() async {
    if (_player != null) {
      await _player!.dispose();
      _player = null;
    }
  }
}
