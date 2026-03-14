import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../models/pixiv_artwork.dart';
import 'pixiv_web_client.dart';

/// Pixiv Web Ajax API クライアント。
/// WebViewのfetch()経由でリクエストし、httpOnly cookieを自動送信する。
class PixivApiClient {
  static const _baseUrl = 'https://www.pixiv.net';
  static const _referer = 'https://www.pixiv.net/';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final PixivWebClient _webClient;
  final Dio _imageDio;

  String? get userId => _webClient.userId;

  PixivApiClient({required PixivWebClient webClient})
      : _webClient = webClient,
        _imageDio = Dio(BaseOptions(
          headers: {
            'Referer': _referer,
            'User-Agent': _userAgent,
          },
          responseType: ResponseType.bytes,
        ));

  /// 作品詳細を取得。
  Future<PixivArtwork> illustDetail(int illustId) async {
    final data = await _webClient.fetchJson(
      '$_baseUrl/ajax/illust/$illustId',
    );
    _checkError(data);
    final body = data['body'] as Map<String, dynamic>;
    return PixivArtwork.fromWebJson(body);
  }

  /// 作品の全ページ情報を取得。
  Future<List<PixivPage>> illustPages(int illustId) async {
    final data = await _webClient.fetchJson(
      '$_baseUrl/ajax/illust/$illustId/pages',
    );
    _checkError(data);
    final pages = data['body'] as List<dynamic>;
    return pages
        .map((p) => PixivPage.fromWebJson(p as Map<String, dynamic>))
        .toList();
  }

  /// おすすめイラストを取得。
  Future<PixivIllustList> illustRecommended({int offset = 0, int limit = 30}) async {
    final data = await _webClient.fetchJson(
      '$_baseUrl/ajax/top/illust?mode=all&lang=ja',
    );
    _checkError(data);
    final body = data['body'] as Map<String, dynamic>;
    final thumbnails = body['thumbnails']?['illust'] as List<dynamic>? ?? [];
    final illusts = thumbnails
        .map((t) => PixivArtwork.fromThumbnailJson(t as Map<String, dynamic>))
        .toList();
    return PixivIllustList(
      illusts: illusts,
      nextOffset: offset + limit < illusts.length ? offset + limit : null,
    );
  }

  /// ユーザーのブックマークを取得。
  Future<PixivIllustList> userBookmarksIllust(
    int userId, {
    String restrict = 'show',
    int offset = 0,
    int limit = 48,
  }) async {
    final data = await _webClient.fetchJson(
      '$_baseUrl/ajax/user/$userId/illusts/bookmarks?tag=&offset=$offset&limit=$limit&rest=$restrict&lang=ja',
    );
    _checkError(data);
    final body = data['body'] as Map<String, dynamic>;
    final works = body['works'] as List<dynamic>? ?? [];
    final total = body['total'] as int? ?? 0;
    return PixivIllustList(
      illusts: works
          .map((w) => PixivArtwork.fromThumbnailJson(w as Map<String, dynamic>))
          .toList(),
      nextOffset: offset + limit < total ? offset + limit : null,
    );
  }

  /// イラストを検索。
  Future<PixivIllustList> searchIllust(
    String word, {
    String sort = 'date_d',
    int page = 1,
  }) async {
    final encodedWord = Uri.encodeComponent(word);
    final data = await _webClient.fetchJson(
      '$_baseUrl/ajax/search/artworks/$encodedWord?word=$encodedWord&order=$sort&s_mode=s_tag_full&p=$page&type=all&lang=ja',
    );
    _checkError(data);
    final body = data['body'] as Map<String, dynamic>;
    final illustManga = body['illustManga'] as Map<String, dynamic>? ?? {};
    final artworks = illustManga['data'] as List<dynamic>? ?? [];
    final total = illustManga['total'] as int? ?? 0;
    return PixivIllustList(
      illusts: artworks
          .map((d) => PixivArtwork.fromThumbnailJson(d as Map<String, dynamic>))
          .toList(),
      nextOffset: artworks.length < total ? page + 1 : null,
    );
  }

  /// ユーザーの作品一覧を取得。
  Future<PixivIllustList> userIllusts(
    int userId, {
    int offset = 0,
    int limit = 48,
  }) async {
    // まずユーザーの全作品IDを取得
    final profileData = await _webClient.fetchJson(
      '$_baseUrl/ajax/user/$userId/profile/all?lang=ja',
    );
    _checkError(profileData);
    final body = profileData['body'] as Map<String, dynamic>;
    final illusts = body['illusts'] as Map<String, dynamic>? ?? {};
    final manga = body['manga'] as Map<String, dynamic>? ?? {};

    // ID一覧（新しい順）
    final allIds = [...illusts.keys, ...manga.keys]
      ..sort((a, b) => int.parse(b).compareTo(int.parse(a)));

    if (allIds.isEmpty) {
      return const PixivIllustList(illusts: [], nextOffset: null);
    }

    // ページネーション
    final pageIds = allIds.skip(offset).take(limit).toList();
    if (pageIds.isEmpty) {
      return const PixivIllustList(illusts: [], nextOffset: null);
    }

    // 作品詳細を一括取得
    final idsParam = pageIds.map((id) => 'ids%5B%5D=$id').join('&');
    final worksData = await _webClient.fetchJson(
      '$_baseUrl/ajax/user/$userId/profile/illusts?$idsParam&work_category=illustManga&is_first_page=0&lang=ja',
    );
    _checkError(worksData);
    final worksBody = worksData['body'] as Map<String, dynamic>? ?? {};
    final works = worksBody['works'] as Map<String, dynamic>? ?? {};

    final artworks = works.values
        .map((w) => PixivArtwork.fromThumbnailJson(w as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.id.compareTo(a.id));

    return PixivIllustList(
      illusts: artworks,
      nextOffset: offset + limit < allIds.length ? offset + limit : null,
    );
  }

  /// 画像をダウンロード（Refererヘッダ付き）。
  Future<Uint8List> downloadImage(
    String imageUrl, {
    void Function(int received, int total)? onProgress,
  }) async {
    final response = await _imageDio.get<List<int>>(
      imageUrl,
      onReceiveProgress: onProgress,
    );
    return Uint8List.fromList(response.data!);
  }

  void _checkError(Map<String, dynamic> data) {
    if (data['error'] == true) {
      final message = data['message'] ?? 'Unknown error';
      print('[PixivAPI] Error: $message');
      throw Exception('Pixiv API error: $message');
    }
  }

  void dispose() {
    _imageDio.close();
  }
}
