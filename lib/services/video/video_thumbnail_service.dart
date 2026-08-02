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

/// The width and height of a raw frame [byteCount] bytes long.
///
/// mpv's screenshot honours the pixel aspect ratio: an anamorphic video
/// (a 720x480 DVD-style file displayed as 720x540) comes back at its
/// **display** size, not its storage size. The buffer's own dimensions are
/// in the screenshot-raw reply, but media_kit discards them for
/// `format: null`, so they are re-derived here and verified against the
/// byte count — reading the buffer with the wrong height was worth two
/// striped tiles before anyone noticed which videos had a PAR.
///
/// Null when no candidate matches; rows might be padded then, and guessing
/// the height from a padded length picks wrong answers silently.
(int, int)? frameSizeOf(int byteCount,
    {required int w, required int h, int? dw, int? dh}) {
  if (dw != null && dh != null && byteCount == dw * dh * 4) return (dw, dh);
  if (byteCount == w * h * 4) return (w, h);
  return null;
}

/// How much of the frame is dark: 0.0 (none) to 1.0 (all of it).
///
/// Dark means **low luminance**, not black. The first version counted only
/// near-black pixels (every channel under 30), and a watermark plate — a
/// bright mark on a dark grey ground — sailed through: its ground sat
/// around 50 per channel, so nothing in the frame counted. Luminance calls
/// that ground what a person does: dark. Every pixel is examined; the walk
/// is integer maths and a few milliseconds even at DVD sizes, once or so
/// per content second.
double darkFractionOf(Uint8List bgra) {
  final pixels = bgra.length ~/ 4;
  var dark = 0;
  for (var i = 0; i + 2 < bgra.length; i += 4) {
    // Rec.601 luma in integer parts-per-thousand; the buffer is BGRA.
    final luma = 114 * bgra[i] + 587 * bgra[i + 1] + 299 * bgra[i + 2];
    if (luma < _darkLuma * 1000) dark++;
  }
  return pixels == 0 ? 0 : dark / pixels;
}

/// Below this luminance (of 255) a pixel counts as dark. 64 is a quarter of
/// full brightness: the dark grey of a title plate is in, a lit scene shot
/// at night is mostly out.
const _darkLuma = 64;

/// Captures video thumbnails using media_kit.
/// Reuses a single Player + VideoController across multiple captures.
/// Serializes captures to prevent concurrent Player.open conflicts.
/// Call [dispose] when no longer needed.
class VideoThumbnailService {
  Player? _player;
  Completer<void>? _lock;

  /// Capture one frame from the given video URL.
  /// Returns the raw frame, or null if capture fails.
  /// Serialized: concurrent calls wait for the previous capture to finish.
  ///
  /// [trustIndex] picks how the frame is reached, and the caller knows the
  /// container:
  ///
  /// - true — a keyframe seek to 3s, shown at once. This trusts the
  ///   demuxer's keyframe flags, which is safe where they are a real index
  ///   (MP4's stss) and not elsewhere: ASF flags lie often enough that the
  ///   "keyframe" is a delta frame, which decodes without its reference
  ///   into striped macroblock noise.
  /// - false — no seeking at all. Play from the start (the one frame that
  ///   never needs a flag to be decodable) at several times speed, sample
  ///   about once per content second, and take the first frame past 1s
  ///   that is not mostly dark — title cards and watermark plates open
  ///   these files, and a fixed 3s landed square on them. If everything
  ///   sampled is dark, the least dark frame seen wins over failing.
  Future<CapturedFrame?> capture(String url,
      {required bool trustIndex}) async {
    // Wait for any in-progress capture
    while (_lock != null) {
      await _lock!.future;
    }
    _lock = Completer<void>();
    try {
      return trustIndex
          ? await _captureAtThreeSeconds(url)
          : await _scanForBrightFrame(url);
    } finally {
      final lock = _lock;
      _lock = null;
      lock?.complete();
    }
  }

  /// One keyframe seek, one frame. For containers whose keyframe list can
  /// be believed.
  Future<CapturedFrame?> _captureAtThreeSeconds(String url) async {
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
      final params = await _sizedVideoParams(player);

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
      return _framed(bytes, params);
    } catch (e, st) {
      return _captureFailed(e, st);
    }
  }

  /// Play from the start and take the first frame that shows something.
  ///
  /// No seek is ever issued, so the demuxer's keyframe flags are never
  /// consulted and the decode is clean from frame one. The clock is run at
  /// [_scanRate] — the sound is off and nobody is watching, so "playback"
  /// is just the decoder being walked forward — and a sample is taken
  /// roughly once per content second up to [_scanWindow].
  Future<CapturedFrame?> _scanForBrightFrame(String url) async {
    _ensurePlayer();
    final player = _player!;

    try {
      await player.open(Media(url), play: true);
      await player.setRate(_scanRate);
      final params = await _sizedVideoParams(player);

      Uint8List? leastDark;
      var leastDarkFraction = 2.0;
      final sampleEvery =
          Duration(milliseconds: 1000 ~/ _scanRate.round());
      final scanned = Stopwatch()..start();
      while (scanned.elapsed <
          _scanWindow * (1 / _scanRate) + const Duration(seconds: 2)) {
        await Future.delayed(sampleEvery);
        final position = player.state.position;
        final bytes = await player.screenshot(format: null);
        if (bytes == null) continue;
        final fraction = darkFractionOf(bytes);
        if (fraction < leastDarkFraction) {
          leastDarkFraction = fraction;
          leastDark = bytes;
        }
        // The first second is skipped even when bright, so a fade-in's
        // opening frames are never candidates. (When the dark test was
        // still a near-black test, this floor sat at 3s to paper over the
        // watermark plate it kept missing; luminance catches the plate by
        // content, so the floor is back to being just a fade-in guard.)
        if (position >= const Duration(seconds: 1) && fraction <= 0.5) break;
        if (position >= _scanWindow) break;
        if (player.state.completed) break;
      }

      if (_player != null) await player.stop();
      if (leastDark == null) return null;
      if (leastDarkFraction > 0.5) {
        _log.info('every sampled frame was mostly dark; keeping the '
            'least dark one (${(leastDarkFraction * 100).round()}%)');
      }
      return _framed(leastDark, params);
    } catch (e, st) {
      return _captureFailed(e, st);
    }
  }

  /// How fast the scan walks the file. 4x keeps the window's worth of
  /// content around two seconds of wall clock; 480p decodes far faster than
  /// that, so the limit is the clock, not the decoder.
  static const _scanRate = 4.0;

  /// How deep into the video the scan is willing to look. Was 20s, and a
  /// video with a dark opening act made the user wait all of it (5s of wall
  /// clock) for a tile; 8s keeps the wait around 2s, and whatever is least
  /// dark by then is usually a fine tile anyway.
  static const _scanWindow = Duration(seconds: 8);

  /// The frame's own size, needed to read the raw pixels. open() resets
  /// videoParams, so this never sees the previous video's answer — and it
  /// fills in over more than one emission: w/h arrive with the demuxed
  /// track, dw/dh (the display size, which is what the buffer of an
  /// anamorphic video actually is) only once the output is configured.
  /// Waiting for the earlier emission got a 720x480 answer for a
  /// 720x540 buffer.
  Future<VideoParams> _sizedVideoParams(Player player) {
    return player.stream.videoParams
        .firstWhere((p) => (p.dw ?? 0) > 0 && (p.dh ?? 0) > 0)
        .timeout(const Duration(seconds: 15));
  }

  CapturedFrame? _framed(Uint8List bytes, VideoParams params) {
    final size = frameSizeOf(bytes.length,
        w: params.w ?? params.dw!,
        h: params.h ?? params.dh!,
        dw: params.dw,
        dh: params.dh);
    if (size == null) {
      _log.warning('cannot size a ${bytes.length}-byte frame '
          '(${params.w}x${params.h}, display ${params.dw}x${params.dh})');
      return null;
    }
    return (bgra: bytes, width: size.$1, height: size.$2);
  }

  Null _captureFailed(Object e, StackTrace st) {
    if (_player == null) {
      // Player was externally disposed (e.g. video playback started)
      _log.info('capture cancelled');
    } else {
      _log.warning('capture failed: $e', e, st);
    }
    return null;
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
        // Keyframe seeks: the only seek anyone issues here is the trusted
        // 3s one, and the scan path never seeks at all.
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
