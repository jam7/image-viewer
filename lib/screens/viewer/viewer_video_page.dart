import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/image_source.dart';
import '../../services/sources/smb_source.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../../widgets/thumbnail_result.dart';

final _log = Logger('ViewerVideo');

/// One video, as a page of the viewer (ADR 010 段階 6).
///
/// A video is an item in a folder like any other, so it is swiped to and away
/// from like any other. What is different is that it holds things while it is
/// on screen — a decoder and a stream from the proxy — and those last exactly
/// as long as this widget does. The viewer shows one page at a time, so there
/// is nothing else to keep track of: leaving the page is what stops it.
class ViewerVideoPage extends StatefulWidget {
  final ImageSource item;
  final SourceRegistry registry;
  final SmbProxyServer proxyServer;

  /// A still of the video, shown until it is asked to play. Null leaves it
  /// black, which is what a video being resumed comes back to.
  final ThumbnailResult? poster;

  /// Where in the video to open, for one being taken up again.
  final Duration startAt;

  /// Whether this should be playing — see the rule in [ViewerScreen]. Turning
  /// true later is how the play button in that overlay reaches down here.
  final bool play;

  /// Reports whether it is playing, so the next video can carry on from here.
  final ValueChanged<bool> onPlayingChanged;

  /// Hands the player up so the viewer can put the controls in its own
  /// overlay, beside everything else about the item. Null on the way out.
  ///
  /// Only once it has something to play. A player with no media answers every
  /// question with zero, and controls built on those answers say a video is at
  /// 0:00 of nothing — over a video the reader stopped eleven seconds in.
  final ValueChanged<Player?> onPlayer;

  const ViewerVideoPage({
    super.key,
    required this.item,
    required this.registry,
    required this.proxyServer,
    required this.poster,
    this.startAt = Duration.zero,
    required this.play,
    required this.onPlayingChanged,
    required this.onPlayer,
  });

  @override
  State<ViewerVideoPage> createState() => _ViewerVideoPageState();
}

class _ViewerVideoPageState extends State<ViewerVideoPage> {
  final _player = Player();
  late final _controller = VideoController(_player);
  String? _token;
  bool _opened = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player.setPlaylistMode(PlaylistMode.single);
    _player.stream.playing.listen((playing) {
      if (mounted) widget.onPlayingChanged(playing);
    });
    if (widget.play) _open(play: true);
  }

  @override
  void didUpdateWidget(ViewerVideoPage old) {
    super.didUpdateWidget(old);
    // The play button for a resting video is in the viewer's overlay, above
    // this page. Pressing it arrives as this flag turning true.
    if (widget.play && !old.play) _open(play: true);
  }

  @override
  void dispose() {
    widget.onPlayer(null);
    // Both ends of the stream: the token is what the proxy is holding a
    // connection open for, and it is ours to let go of.
    if (_token != null) widget.proxyServer.invalidateToken(_token!);
    _player.dispose();
    super.dispose();
  }

  Future<void> _open({required bool play}) async {
    if (_opened) {
      if (play) await _player.play();
      return;
    }
    _opened = true;
    try {
      final provider = await widget.registry.resolve(
        widget.item.sourceKey ?? '',
        context,
      );
      if (provider is! SmbSource) {
        throw UnsupportedError('${widget.item.sourceKey} cannot serve video');
      }
      final url =
          await widget.proxyServer.registerSession(provider, widget.item.uri);
      _token = url.split('/').last;
      // Opening at the mark rather than seeking after it: a seek would play
      // the opening seconds first, sound and all, on the way past.
      await _player.open(
        Media(url, start: widget.startAt > Duration.zero ? widget.startAt : null),
        play: play,
      );
      if (!mounted) return;
      widget.onPlayer(_player);
      setState(() {});
    } catch (e, st) {
      _log.warning('playback failed: ${widget.item.name}', e, st);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    if (!_opened) return _poster();
    // No controls of its own: they fight the viewer's for taps and drags, and
    // draw a second set of bars over the ones already there. Ours are in the
    // viewer's overlay, from the player handed up in [initState].
    return Video(controller: _controller, controls: NoVideoControls);
  }

  /// The still, with the one thing worth pressing on it. Swiping past a video
  /// should not start it playing — nor make a sound (ADR 010 決定 8).
  Widget _poster() {
    final poster = widget.poster;
    return GestureDetector(
      onTap: () => setState(() => _open(play: true)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (poster is ThumbnailData)
            Image.memory(poster.data, fit: BoxFit.contain),
          const Center(
            child: Icon(Icons.play_circle_outline,
                color: Colors.white70, size: 96),
          ),
        ],
      ),
    );
  }
}
