import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../models/pixiv_artwork.dart';
import '../pixiv/pixiv_api_client.dart';
import 'image_source_provider.dart';

final _log = Logger('PixivSource');

/// Pixiv を ImageSourceProvider として実装。
class PixivSource extends ImageSourceProvider {
  final PixivApiClient _client;

  int? _nextOffset;

  /// Told the item id and the address that replaced a stored thumbnail URL,
  /// for whoever is holding the stale one. Only the favorites list stores such
  /// a URL, and this source has no view of it, so the write-back is the
  /// listener's to do.
  void Function(String imageId, String url)? onThumbnailUrlRefreshed;

  PixivSource({required PixivApiClient client}) : _client = client;

  PixivApiClient get client => _client;

  /// Stateless page fetch (ADR 007). [cursor] is the Pixiv offset (bookmarks /
  /// user works, in item count) or page number (search, 1-based); null = first
  /// page. Returns the expanded items plus [PageResult.nextCursor] (from the
  /// endpoint's nextOffset), null at the end.
  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async {
    final effectivePath = path ?? '/top';
    final offset = cursor as int?;
    final PixivIllustList result;

    if (effectivePath.startsWith('/bookmarks')) {
      final userId = _client.userId;
      if (userId == null) throw Exception('Pixiv userId not available');
      result = await _client.userBookmarksIllust(
        int.parse(userId),
        offset: offset ?? 0,
      );
    } else if (effectivePath.startsWith('/user/')) {
      final userId = effectivePath.substring('/user/'.length);
      result = await _client.userIllusts(
        int.parse(userId),
        offset: offset ?? 0,
      );
    } else if (effectivePath.startsWith('/search')) {
      final uri = Uri.parse('https://dummy$effectivePath');
      final word = uri.queryParameters['word'] ?? '';
      if (word.isEmpty) throw Exception('検索ワードが必要です');
      // s_mode (tag match) and order ride in the path query so the gallery can
      // change them at runtime. Default to full-tag match / newest.
      final sMode = uri.queryParameters['s_mode'] ?? 's_tag_full';
      final order = uri.queryParameters['order'] ?? 'date_d';
      result = await _client.searchIllust(
        word,
        sMode: sMode,
        sort: order,
        page: offset ?? 1,
      );
    } else {
      result = await _client.illustTop();
    }

    return PageResult(
      items: _expandArtworks(result.illusts),
      nextCursor: result.nextOffset,
    );
  }

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    // Stateful wrapper over loadPage for the current (non-virtualized) screen:
    // carry the cursor in _nextOffset. GallerySession will call loadPage directly.
    final page = await loadPage(path: path, cursor: _nextOffset);
    _nextOffset = page.nextCursor as int?;
    return page.items;
  }

  bool get hasNextPage => _nextOffset != null;

  void resetPagination() {
    _nextOffset = null;
  }

  /// 作品の全ページをImageSourceリストとして返す。
  /// ビューアで作品タップ時に呼ぶ。高解像度URLを取得する。
  @override
  Future<List<ImageSource>> resolvePages(ImageSource source) async {
    final illustId = source.metadata?['illustId'] as int?;
    if (illustId == null) return [source];

    final pages = await _client.illustPages(illustId);
    if (pages.isEmpty) return [source];

    return pages.asMap().entries.map((entry) {
      final i = entry.key;
      final page = entry.value;
      final pageId = pages.length > 1 ? '${illustId}_p$i' : '$illustId';
      final pageName = pages.length > 1
          ? '${source.name} (${i + 1}/${pages.length})'
          : source.name;
      return ImageSource(
        id: pageId,
        name: pageName,
        uri: page.originalUrl,
        type: ImageSourceType.pixiv,
        sourceKey: 'pixiv:default',
        metadata: {
          ...?source.metadata,
          'illustId': illustId,
          'pageIndex': i,
          'regularUrl': page.regularUrl,
          'originalUrl': page.originalUrl,
          'width': page.width,
          'height': page.height,
        },
      );
    }).toList();
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    final url = source.metadata?['thumbnailUrl'] as String;
    try {
      return await _client.downloadImage(url);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
      return _refetchThumbnail(source, url, e);
    }
  }

  /// Second attempt at a thumbnail whose stored URL is gone.
  ///
  /// A listing's `thumbnailUrl` is the one value we store and later replay
  /// verbatim — a favourite keeps the URL it was starred with. Page URLs never
  /// go stale because [resolvePages] re-derives them from the API on every
  /// open; this one has no such step, and Pixiv does re-issue the addresses
  /// (`img-master/..._square1200` turning into `custom-thumb/..._custom1200`),
  /// so an old favourite eventually 404s while the work itself still opens.
  ///
  /// Only a 404 gets here. Any other failure — offline, not signed in — must
  /// stay a plain failure, or a disconnected Pixiv would send every thumbnail
  /// in the list through the API for nothing.
  ///
  /// The new address is reported through [onThumbnailUrlRefreshed] so the
  /// holder of the stale one can keep it. The thumbnail cache alone is not
  /// enough: it is evicted by LRU, and the stale URL then costs a 404 plus an
  /// API call every time it comes back.
  Future<Uint8List> _refetchThumbnail(
    ImageSource source,
    String staleUrl,
    DioException failure,
  ) async {
    final illustId = source.metadata?['illustId'] as int?;
    if (illustId == null) throw failure;

    final fresh = (await _client.illustDetail(illustId)).thumbnailUrl;
    if (fresh.isEmpty || fresh == staleUrl) {
      _log.warning('thumbnail 404 and the API gives the same URL: $staleUrl');
      throw failure;
    }

    final bytes = await _client.downloadImage(fresh);
    _log.info('thumbnail URL refreshed for $illustId');
    onThumbnailUrlRefreshed?.call(source.id, fresh);
    return bytes;
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) {
    // regularUrl（中サイズ）を優先、なければoriginalUrl、最後にuri
    final url = source.metadata?['regularUrl'] as String?
        ?? source.metadata?['originalUrl'] as String?
        ?? source.uri;
    return _client.downloadImage(url, onProgress: onProgress);
  }

  @override
  Future<void> dispose() async {
    // PixivApiClient is shared across all PixivSource instances.
    // Its lifecycle is managed by SourceRegistry / _AppRoot, not here.
  }

  List<ImageSource> _expandArtworks(List<PixivArtwork> artworks) {
    final sources = <ImageSource>[];

    for (final artwork in artworks) {
      sources.add(ImageSource(
        id: '${artwork.id}',
        name: artwork.title,
        uri: artwork.thumbnailUrl,
        type: ImageSourceType.pixiv,
        sourceKey: 'pixiv:default',
        metadata: {
          'illustId': artwork.id,
          'thumbnailUrl': artwork.thumbnailUrl,
          'author': artwork.user.name,
          'authorId': artwork.user.id,
          'tags': artwork.tags,
          'pageCount': artwork.pageCount,
          'width': artwork.width,
          'height': artwork.height,
          'bookmarks': artwork.totalBookmarks,
          'views': artwork.totalView,
        },
      ));
    }

    return sources;
  }
}
