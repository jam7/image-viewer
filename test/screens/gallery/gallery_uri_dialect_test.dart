import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/gallery_uri_dialect.dart';

/// The per-source URI rules (2C-2). These are pure on purpose: a tab restored
/// from disk has to say where it is before it can connect, so nothing here may
/// need a provider, a store or a network.
void main() {
  group('parsePlace', () {
    test('reads a place for every scheme the app has', () {
      for (final address in [
        'home://default',
        'fav://default',
        'pixiv://default/top',
        'smb://1700000000000/books',
      ]) {
        expect(parsePlace(address), isNotNull, reason: address);
      }
    });

    test('surrounding spaces are not part of the address', () {
      expect(parsePlace('  pixiv://default/top  '),
          equals(Uri.parse('pixiv://default/top')));
    });

    test('anything that is not a place is a search, not an error', () {
      // Null is the address field's signal to search instead. A half-typed
      // scheme has to land here rather than in a dialog: it is what happens
      // when someone hits enter early.
      for (final input in [
        'books', // plain words
        '', // nothing at all
        'smb://', // no instance yet
        'https://example.invalid/', // a scheme we do not serve
        'pixiv:/default/top', // one slash short of an authority
      ]) {
        expect(parsePlace(input), isNull, reason: '"$input"');
      }
    });
  });

  group('describePlace', () {
    test('names the places that have one name', () {
      expect(describePlace(homeGalleryUri()), 'ホーム');
      expect(describePlace(favGalleryUri()), 'お気に入り');
      expect(describePlace(pixivGalleryUri('/top')), 'Pixiv');
      expect(describePlace(pixivGalleryUri('/bookmarks')), 'ブックマーク一覧');
    });

    test('an author is known by number until the source says otherwise', () {
      expect(describePlace(pixivGalleryUri('/user/1700000000000')),
          '1700000000000 の作品');
    });

    test('a search shows its word', () {
      expect(describePlace(pixivSearchUri('books')), 'books');
    });

    test('and shows the options only when they are not the usual ones', () {
      // Forgetting why a list looks the way it does is this UI's typical
      // accident, so a search that asked for something unusual says so.
      expect(describePlace(pixivSearchUri('books', mode: 's_tag')),
          'books (部分)');
      expect(describePlace(pixivSearchUri('books', order: 'date')),
          'books (古い順)');
      expect(
          describePlace(pixivSearchUri('books', mode: 's_tag', order: 'date')),
          'books (部分・古い順)');
    });

    test('an SMB directory gives its whole path, unlike the tab chip', () {
      // The chip shortens because it only has to tell two tabs apart; the
      // toolbar has to say exactly where this is.
      expect(describePlace(smbGalleryUri('1700000000000', r'books\series\vol2')),
          'books/series/vol2');
      expect(describePlace(smbGalleryUri('1700000000000', '/')), '/');
    });
  });

  group('searchFrom', () {
    test('a Pixiv search starts from the defaults', () {
      final uri = searchFrom(pixivGalleryUri('/top'), 'books')!;
      expect(uri.queryParameters['word'], 'books');
      expect(uri.queryParameters['s_mode'], pixivDefaultSearchMode);
      expect(uri.queryParameters['order'], pixivDefaultSearchOrder);
    });

    test('refining a search keeps the options it was made with', () {
      // Retyping the word is not a request to go back to exact matching.
      final from = pixivSearchUri('books', mode: 's_tag', order: 'date');
      final uri = searchFrom(from, 'series')!;
      expect(uri.queryParameters['word'], 'series');
      expect(uri.queryParameters['s_mode'], 's_tag');
      expect(uri.queryParameters['order'], 'date');
    });

    test('sources with no search say so rather than inventing one', () {
      expect(searchFrom(homeGalleryUri(), 'books'), isNull);
      expect(searchFrom(favGalleryUri(), 'books'), isNull);
      expect(searchFrom(smbGalleryUri('1700000000000', '/'), 'books'), isNull);
    });

    test('the hint agrees with whether there is a search at all', () {
      expect(searchHintFor(pixivGalleryUri('/top')), isNotNull);
      expect(searchHintFor(homeGalleryUri()), isNull);
      expect(searchHintFor(smbGalleryUri('1700000000000', '/')), isNull);
    });
  });

  group('titleFrom', () {
    ImageSource work({String? author}) => ImageSource(
          id: 'a',
          name: 'a',
          uri: 'a',
          type: ImageSourceType.pixiv,
          metadata: {'author': ?author},
        );

    test('an author page is named by the works on it', () {
      expect(
          titleFromItems(pixivGalleryUri('/user/1700000000000'),
              [work(author: 'テスト作者')]),
          'テスト作者 の作品',
      );
    });

    test('nothing to learn where the URI already said it all', () {
      // A search knows its own word; the top page has no name to find.
      expect(titleFromItems(pixivSearchUri('books'), [work(author: 'テスト作者')]),
          isNull);
      expect(titleFromItems(pixivGalleryUri('/top'), [work(author: 'テスト作者')]),
          isNull);
    });

    test('an empty or silent page teaches nothing', () {
      expect(titleFromItems(pixivGalleryUri('/user/1700000000000'), []), isNull);
      expect(titleFromItems(pixivGalleryUri('/user/1700000000000'), [work()]),
          isNull);
    });

    test('sources with no such name say so', () {
      expect(titleFromItems(homeGalleryUri(), [work(author: 'テスト作者')]), isNull);
      expect(
          titleFromItems(smbGalleryUri('1700000000000', '/books'), [work()]),
          isNull);
    });
  });

  group('placeTitle', () {
    test('a name the source learned beats what the address can say', () {
      expect(placeTitle(pixivGalleryUri('/user/1700000000000'), 'テスト作者 の作品'),
          'テスト作者 の作品');
    });

    test('and the address answers when there is no such name', () {
      expect(placeTitle(pixivGalleryUri('/user/1700000000000'), ''),
          '1700000000000 の作品');
    });
  });
}
