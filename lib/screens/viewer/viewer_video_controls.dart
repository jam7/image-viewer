import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// Play, seek and skip, for the video the viewer is showing.
///
/// In the viewer's own overlay rather than the player's, so that there is one
/// set of bars over the picture instead of two, and so the horizontal drag
/// stays the viewer's — it means "the next item", and a player that took it
/// for seeking would make swiping out of a video impossible (ADR 010 決定 8).
class ViewerVideoControls extends StatelessWidget {
  final Player player;

  const ViewerVideoControls({super.key, required this.player});

  /// Two sizes of jump: one for a line missed, one for a scene.
  static const _skips = [-60, -10, 10, 60];

  void _skip(Duration by) {
    final to = player.state.position + by;
    player.seek(to < Duration.zero ? Duration.zero : to);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, position) => Row(
        children: [
          StreamBuilder<bool>(
            stream: player.stream.playing,
            initialData: player.state.playing,
            builder: (context, playing) => IconButton(
              icon: Icon(
                playing.data == true ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: player.playOrPause,
              tooltip: playing.data == true ? '一時停止' : '再生',
            ),
          ),
          for (final seconds in _skips)
            IconButton(
              icon: _skipIcon(seconds),
              onPressed: () => _skip(Duration(seconds: seconds)),
              tooltip: '${seconds.abs()} 秒${seconds < 0 ? '戻る' : '進む'}',
              visualDensity: VisualDensity.compact,
            ),
          Expanded(child: _seekBar(position.data ?? Duration.zero)),
          Text(
            _clock(position.data ?? Duration.zero),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// A circular arrow with the number of seconds in it, the way Material
  /// draws its own ten-second one.
  ///
  /// Built here rather than taken from the icon set because the set stops at
  /// thirty, and the nearest thing to a sixty is a double arrow — which in
  /// every other player means the next track. All four are drawn the same way
  /// so that they read as one row of the same kind of button.
  static Widget _skipIcon(int seconds) {
    final back = seconds < 0;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.scale(
            scaleX: back ? 1 : -1, // Icons.replay turns anticlockwise
            child: const Icon(Icons.replay, color: Colors.white, size: 24),
          ),
          Padding(
            // The glyph's gap is a little below its middle.
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${seconds.abs()}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seekBar(Duration position) {
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (context, duration) {
        final total = duration.data ?? Duration.zero;
        if (total == Duration.zero) return const SizedBox.shrink();
        final at = position > total ? total : position;
        return Slider(
          value: at.inMilliseconds.toDouble(),
          max: total.inMilliseconds.toDouble(),
          onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
        );
      },
    );
  }

  /// `m:ss`, or `h:mm:ss` once there is an hour to show.
  static String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final minutes = d.inMinutes.remainder(60);
    final seconds = two(d.inSeconds.remainder(60));
    if (d.inHours == 0) return '$minutes:$seconds';
    return '${d.inHours}:${two(minutes)}:$seconds';
  }
}

/// The same bar for a video that is not open: where it was left, and the one
/// button that opens it there.
///
/// It exists so that coming back to a tab shows the place rather than the
/// picture. Drawing the frame itself would mean connecting to the share and
/// decoding on arrival — every time a tab is glanced at, for a video that may
/// never be started again.
class ViewerVideoRestingBar extends StatelessWidget {
  final Duration at;
  final Duration total;
  final VoidCallback onPlay;

  const ViewerVideoRestingBar({
    super.key,
    required this.at,
    required this.total,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final position = at > total ? total : at;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.play_arrow, color: Colors.white),
          onPressed: onPlay,
          tooltip: '再生',
        ),
        Expanded(
          child: Slider(
            value: position.inMilliseconds.toDouble(),
            max: total.inMilliseconds.toDouble(),
            // Dragging would have to open the video to seek in it, which is
            // what the play button is for. It shows; it does not steer.
            onChanged: null,
          ),
        ),
        Text(
          ViewerVideoControls._clock(position),
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
