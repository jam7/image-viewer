import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/pixiv_artwork.dart';
import 'package:image_viewer/services/pixiv/pixiv_api_client.dart';
import 'package:image_viewer/services/pixiv/pixiv_web_client.dart';
import 'package:image_viewer/services/sources/pixiv_source.dart';

/// Verifies PixivSource.loadPage maps the opaque cursor to the right endpoint
/// argument (page for search, offset for bookmarks) and propagates nextCursor,
/// and that listImages delegates to it statefully (ADR 007).
void main() {
  test('search: cursor is the page number; nextCursor propagates', () async {
    final client = _FakeApiClient(returnNextOffset: 3);
    final source = PixivSource(client: client);

    final page = await source.loadPage(path: '/search?word=cat', cursor: 2);

    expect(client.method, 'search');
    expect(client.page, 2);
    expect(page.nextCursor, 3);
    expect(page.hasMore, isTrue);
  });

  test('search first page: null cursor defaults to page 1', () async {
    final client = _FakeApiClient(returnNextOffset: null);
    final source = PixivSource(client: client);

    final page = await source.loadPage(path: '/search?word=cat');

    expect(client.page, 1);
    expect(page.nextCursor, isNull);
    expect(page.hasMore, isFalse);
  });

  test('bookmarks: cursor is the offset', () async {
    final client = _FakeApiClient(returnNextOffset: 96);
    final source = PixivSource(client: client);

    await source.loadPage(path: '/bookmarks', cursor: 48);

    expect(client.method, 'bookmarks');
    expect(client.offset, 48);
  });

  test('listImages delegates to loadPage and advances the cursor', () async {
    final client = _FakeApiClient(returnNextOffset: 2);
    final source = PixivSource(client: client);

    await source.listImages(path: '/search?word=cat'); // page 1 -> next 2
    expect(client.page, 1);
    expect(source.hasNextPage, isTrue);

    await source.listImages(path: '/search?word=cat'); // now page 2
    expect(client.page, 2);
  });
}

/// Fake API client recording the call and returning empty results with a
/// canned nextOffset.
class _FakeApiClient extends PixivApiClient {
  final int? returnNextOffset;
  String? method;
  int? page;
  int? offset;

  _FakeApiClient({this.returnNextOffset})
      : super(webClient: PixivWebClient());

  @override
  String? get userId => '999';

  @override
  Future<PixivIllustList> searchIllust(String word,
      {String sort = 'date_d', String sMode = 's_tag_full', int page = 1}) async {
    method = 'search';
    this.page = page;
    return PixivIllustList(illusts: const [], nextOffset: returnNextOffset);
  }

  @override
  Future<PixivIllustList> userBookmarksIllust(int userId,
      {String restrict = 'show', int offset = 0, int limit = 48}) async {
    method = 'bookmarks';
    this.offset = offset;
    return PixivIllustList(illusts: const [], nextOffset: returnNextOffset);
  }
}
