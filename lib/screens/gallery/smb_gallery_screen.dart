import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import 'gallery_session.dart';
import 'gallery_uri.dart';
import 'widgets/gallery_grid.dart';
import 'widgets/gallery_keyboard_scrollable.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/sources/smb_source.dart';
import '../../services/sources/source_registry.dart';
import '../../services/video/smb_proxy_server.dart';
import '../../widgets/thumbnail_result.dart';
import '../video/video_player_screen.dart';
import '../viewer/viewer_screen.dart';

final _log = Logger('SmbGallery');

/// SMBディレクトリブラウズ画面。
class SmbGalleryScreen extends StatefulWidget {
  final SmbSource source;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SourceRegistry registry;
  final SmbProxyServer proxyServer;
  final String initialPath;

  const SmbGalleryScreen({
    super.key,
    required this.source,
    required this.cacheManager,
    required this.favoritesStore,
    required this.registry,
    required this.proxyServer,
    this.initialPath = '/',
  });

  @override
  State<SmbGalleryScreen> createState() => _SmbGalleryScreenState();
}

class _SmbGalleryScreenState extends State<SmbGalleryScreen> {
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  late final GallerySession _session;
  bool _isLoading = false;
  String? _error;
  bool _isPopping = false;

  @override
  void initState() {
    super.initState();
    _session = GallerySession.fromUri(
      smbGalleryUri(widget.source.config.id, widget.initialPath),
      provider: widget.source,
      cacheManager: widget.cacheManager,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _loadDirectory();
  }

  @override
  void deactivate() {
    _session.detach();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _session.attach();
  }

  @override
  void dispose() {
    _session.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _session.loadNextPage();
      if (!mounted) return;
      setState(() => _isLoading = false);
      await _session.thumbnails.loadNextBatch();
      _loadMoreIfNeeded();
    } catch (e, st) {
      _log.warning('loadDirectory error', e, st);
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _loadMoreIfNeeded() {
    if (_session.thumbnails.allDispatched) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0) {
        _session.thumbnails.loadNextBatch();
      }
    });
  }

  void _onItemTap(ImageSource item) {
    if (item.metadata?['isDirectory'] == true) {
      final path = item.metadata?['path'] as String? ?? '/';
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SmbGalleryScreen(
          source: widget.source,
          cacheManager: widget.cacheManager,
          favoritesStore: widget.favoritesStore,
          registry: widget.registry,
          proxyServer: widget.proxyServer,
          initialPath: path,
        ),
      ));
    } else if (item.metadata?['isVideo'] == true) {
      _session.thumbnails.cancel();
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          item: item,
          source: widget.source,
          proxyServer: widget.proxyServer,
        ),
      )).then((_) {
        _session.retryUnsupportedThumbnails();
        _session.thumbnails.retryInterrupted();
      });
    } else {
      final viewerItems =
          _session.thumbnailItems.where((i) => i.metadata?['isVideo'] != true).toList();
      final index = viewerItems.indexWhere((i) => i.id == item.id);
      if (index >= 0) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ViewerScreen(
            items: viewerItems,
            initialIndex: index,
            registry: widget.registry,
            cacheManager: widget.cacheManager,
            favoritesStore: widget.favoritesStore,
          ),
        )).then((_) => _session.retryUnsupportedThumbnails());
      }
    }
  }


  /// Guard against multiple pop calls in the same frame
  /// (e.g. ESC key and mouse back button firing simultaneously).
  void _popOnce() {
    if (_isPopping) return;
    _isPopping = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return GalleryKeyboardScrollable(
      focusNode: _focusNode,
      scrollController: _scrollController,
      onPop: _popOnce,
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.initialPath,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(child: _buildGrid()),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GalleryGrid(
      scrollController: _scrollController,
      items: _session.loaded,
      isLoading: _isLoading,
      emptyMessage: 'ファイルが見つかりませんでした',
      tileBuilder: _buildTile,
      anchor: _session.anchor,
      onAnchorChanged: (a) => _session.anchor = a,
    );
  }

  Widget _buildTile(BuildContext context, int index) {
    final item = _session.loaded[index];
    final isDir = item.metadata?['isDirectory'] == true;
    final thumb = _session.thumbnailFor(item.id);

    // Trigger next batch when an item beyond current batch becomes visible.
    if (_session.needsBatchFor(item)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _session.thumbnails.loadNextBatch();
      });
    }

    final isVideo = item.metadata?['isVideo'] == true;
    final videoThumb = isVideo ? thumb : null;

    return GestureDetector(
      onTap: () => _onItemTap(item),
      child: isDir
          ? _buildIconTile(item.name, Icons.folder, Colors.amber)
          : isVideo
          ? (videoThumb is ThumbnailData
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(videoThumb.data, fit: BoxFit.cover),
                    const Center(
                      child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 48),
                    ),
                  ],
                )
              : _buildIconTile(item.name, Icons.play_circle_outline, Colors.deepPurple))
          : switch (thumb) {
              ThumbnailData(data: final d) =>
                Image.memory(d, fit: BoxFit.cover),
              ThumbnailFailed(reason: ThumbnailFailReason.notSupported) =>
                _buildIconTile(item.name, Icons.archive, Colors.blueGrey),
              ThumbnailFailed(reason: ThumbnailFailReason.timeout) =>
                _buildIconTile(item.name, Icons.broken_image, Colors.red[300]!),
              null => Container(
                  color: Colors.grey[300],
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            },
    );
  }

  Widget _buildIconTile(String name, IconData icon, Color color) {
    return Container(
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 4),
          Text(
            name,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

