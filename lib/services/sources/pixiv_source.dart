import 'dart:typed_data';

import '../../models/image_source.dart';
import '../../models/pixiv_artwork.dart';
import '../pixiv/pixiv_api_client.dart';
import 'image_source_provider.dart';

/// Pixiv を ImageSourceProvider として実装。
class PixivSource implements ImageSourceProvider {
  final PixivApiClient _client;

  int? _nextOffset;

  PixivSource({required PixivApiClient client}) : _client = client;

  PixivApiClient get client => _client;

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    final PixivIllustList result;

    final effectivePath = path ?? '/recommended';

    if (effectivePath.startsWith('/bookmarks')) {
      final userId = _client.userId ?? await _client.waitForUserId();
      result = await _client.userBookmarksIllust(
        int.parse(userId),
        offset: _nextOffset ?? 0,
      );
    } else if (effectivePath.startsWith('/user/')) {
      final userId = effectivePath.substring('/user/'.length);
      result = await _client.userIllusts(
        int.parse(userId),
        offset: _nextOffset ?? 0,
      );
    } else if (effectivePath.startsWith('/search')) {
      final uri = Uri.parse('https://dummy$effectivePath');
      final word = uri.queryParameters['word'] ?? '';
      if (word.isEmpty) throw Exception('検索ワードが必要です');
      result = await _client.searchIllust(word, page: _nextOffset ?? 1);
    } else {
      result = await _client.illustRecommended(offset: _nextOffset ?? 0);
    }

    _nextOffset = result.nextOffset;

    return _expandArtworks(result.illusts);
  }

  bool get hasNextPage => _nextOffset != null;

  void resetPagination() {
    _nextOffset = null;
  }

  /// 作品の全ページをImageSourceリストとして返す。
  /// ビューアで作品タップ時に呼ぶ。高解像度URLを取得する。
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
  Future<Uint8List> fetchThumbnail(ImageSource source) {
    return _client.downloadImage(source.metadata?['thumbnailUrl'] as String);
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
    _client.dispose();
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
