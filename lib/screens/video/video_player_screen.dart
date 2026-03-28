import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/image_source.dart';
import '../../services/sources/smb_source.dart';
import '../../services/video/smb_proxy_server.dart';

final _log = Logger('VideoPlayer');

class VideoPlayerScreen extends StatefulWidget {
  final ImageSource item;
  final SmbSource source;
  final SmbProxyServer proxyServer;

  const VideoPlayerScreen({
    super.key,
    required this.item,
    required this.source,
    required this.proxyServer,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  final _focusNode = FocusNode();
  String? _token;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.setPlaylistMode(PlaylistMode.single);
    _startPlayback();
  }

  Future<void> _startPlayback() async {
    try {
      final filePath = widget.item.uri;
      _log.info('Starting playback: ${widget.item.name}');
      final url = await widget.proxyServer.registerSession(widget.source, filePath);
      _token = url.split('/').last;
      await _player.open(Media(url));
      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e, st) {
      _log.warning('Playback failed', e, st);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    if (_token != null) {
      widget.proxyServer.invalidateToken(_token!);
    }
    _player.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      _player.playOrPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _player.seek(_player.state.position + const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _player.seek(_player.state.position - const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              widget.item.name,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Text(_error!, style: const TextStyle(color: Colors.red)),
                    )
                  : MaterialVideoControlsTheme(
                      normal: const MaterialVideoControlsThemeData(
                        padding: EdgeInsets.only(bottom: 100.0),
                        seekBarContainerHeight: 72.0,
                      ),
                      fullscreen: const MaterialVideoControlsThemeData(),
                      child: SafeArea(child: Video(controller: _controller)),
                    ),
        ),
      ),
    );
  }
}
