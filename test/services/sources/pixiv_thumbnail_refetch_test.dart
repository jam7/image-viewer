import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/pixiv_artwork.dart';
import 'package:image_viewer/services/pixiv/pixiv_api_client.dart';
import 'package:image_viewer/services/pixiv/pixiv_web_client.dart';
import 'package:image_viewer/services/sources/pixiv_source.dart';

/// A favourite stores the thumbnail URL it was starred with and replays it,
/// while page URLs are re-derived on every open — so only the thumbnail goes
/// stale, and Pixiv answers the old address with a 404. Fetching a fresh URL
/// is worth it exactly then: any other failure must not put the whole visible
/// list through the API.
void main() {
  ImageSource favourite({int? illustId = 42}) => ImageSource(
        id: '42',
        name: 'work',
        uri: 'https://i.pximg.net/stale.jpg',
        type: ImageSourceType.pixiv,
        sourceKey: 'pixiv:default',
        metadata: {
          'thumbnailUrl': 'https://i.pximg.net/stale.jpg',
          'illustId': ?illustId,
        },
      );

  test('a 404 thumbnail is retried at the URL the API gives now', () async {
    final client = _FakeApiClient(
      failing: {'https://i.pximg.net/stale.jpg': 404},
      detailThumbnailUrl: 'https://i.pximg.net/fresh.jpg',
    );

    final bytes = await PixivSource(client: client).fetchThumbnail(favourite());

    expect(client.detailCalls, [42]);
    expect(client.downloaded, [
      'https://i.pximg.net/stale.jpg',
      'https://i.pximg.net/fresh.jpg',
    ]);
    expect(bytes, [1]);
  });

  test('the new URL is reported for whoever stored the old one', () async {
    final client = _FakeApiClient(
      failing: {'https://i.pximg.net/stale.jpg': 404},
      detailThumbnailUrl: 'https://i.pximg.net/fresh.jpg',
    );
    final refreshed = <String, String>{};
    final source = PixivSource(client: client)
      ..onThumbnailUrlRefreshed = (id, url) => refreshed[id] = url;

    await source.fetchThumbnail(favourite());

    expect(refreshed, {'42': 'https://i.pximg.net/fresh.jpg'});
  });

  test('nothing is reported when the new URL does not work either', () async {
    // Replacing a stored URL with one that also fails would be worse than
    // leaving it: the entry would still 404, having lost its history.
    final client = _FakeApiClient(
      failing: {
        'https://i.pximg.net/stale.jpg': 404,
        'https://i.pximg.net/fresh.jpg': 404,
      },
      detailThumbnailUrl: 'https://i.pximg.net/fresh.jpg',
    );
    final refreshed = <String, String>{};
    final source = PixivSource(client: client)
      ..onThumbnailUrlRefreshed = (id, url) => refreshed[id] = url;

    await expectLater(
        source.fetchThumbnail(favourite()), throwsA(isA<DioException>()));
    expect(refreshed, isEmpty);
  });

  test('any other failure is not sent through the API', () async {
    // Offline, or signed out: the URL is fine and re-asking would cost one API
    // call per thumbnail on screen.
    final client = _FakeApiClient(
      failing: {'https://i.pximg.net/stale.jpg': 503},
      detailThumbnailUrl: 'https://i.pximg.net/fresh.jpg',
    );

    await expectLater(
      PixivSource(client: client).fetchThumbnail(favourite()),
      throwsA(isA<DioException>()),
    );
    expect(client.detailCalls, isEmpty);
  });

  test('a working URL is downloaded once, with no API call', () async {
    final client = _FakeApiClient(detailThumbnailUrl: 'unused');

    await PixivSource(client: client).fetchThumbnail(favourite());

    expect(client.downloaded, ['https://i.pximg.net/stale.jpg']);
    expect(client.detailCalls, isEmpty);
  });

  test('an unchanged URL fails rather than downloading twice', () async {
    final client = _FakeApiClient(
      failing: {'https://i.pximg.net/stale.jpg': 404},
      detailThumbnailUrl: 'https://i.pximg.net/stale.jpg',
    );

    await expectLater(
      PixivSource(client: client).fetchThumbnail(favourite()),
      throwsA(isA<DioException>()),
    );
    expect(client.downloaded, ['https://i.pximg.net/stale.jpg']);
  });

  test('without an illustId there is nothing to ask the API for', () async {
    final client = _FakeApiClient(
      failing: {'https://i.pximg.net/stale.jpg': 404},
      detailThumbnailUrl: 'https://i.pximg.net/fresh.jpg',
    );

    await expectLater(
      PixivSource(client: client).fetchThumbnail(favourite(illustId: null)),
      throwsA(isA<DioException>()),
    );
    expect(client.detailCalls, isEmpty);
  });
}

/// Records downloads and detail lookups; answers listed URLs with an HTTP
/// error the way Dio does.
class _FakeApiClient extends PixivApiClient {
  final Map<String, int> failing;
  final String detailThumbnailUrl;
  final List<String> downloaded = [];
  final List<int> detailCalls = [];

  _FakeApiClient({
    this.failing = const {},
    required this.detailThumbnailUrl,
  }) : super(webClient: PixivWebClient());

  @override
  Future<Uint8List> downloadImage(
    String imageUrl, {
    void Function(int received, int total)? onProgress,
  }) async {
    downloaded.add(imageUrl);
    final status = failing[imageUrl];
    if (status != null) {
      final options = RequestOptions(path: imageUrl);
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: status),
        type: DioExceptionType.badResponse,
      );
    }
    return Uint8List.fromList(const [1]);
  }

  @override
  Future<PixivArtwork> illustDetail(int illustId) async {
    detailCalls.add(illustId);
    return PixivArtwork(
      id: illustId,
      title: 'work',
      caption: '',
      user: const PixivUser(id: 1, name: 'author'),
      tags: const [],
      imageUrls: PixivImageUrls(
        thumb: detailThumbnailUrl,
        small: detailThumbnailUrl,
        regular: detailThumbnailUrl,
        original: null,
      ),
      pages: const [],
      pageCount: 1,
      width: 100,
      height: 100,
      isBookmarked: false,
      totalBookmarks: 0,
      totalView: 0,
    );
  }
}
