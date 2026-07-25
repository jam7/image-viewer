import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/screens/gallery/gallery_uri.dart';

/// Pins the URI <-> place mapping. The SMB half matters most: real share paths
/// are backslash-separated and hold spaces, `#`, `%` and non-ASCII, and a URI
/// carries them only if the separator is translated and the rest is
/// percent-encoded. Getting this wrong shows up as "that one folder won't open".
void main() {
  group('SMB', () {
    const configId = '1700000000000';

    void roundTrips(String path, String expected, {String? asUri}) {
      final uri = smbGalleryUri(configId, path);
      if (asUri != null) expect(uri.toString(), asUri);
      // Via a string, as a link or a restored tab would arrive.
      expect(smbPathOf(Uri.parse(uri.toString())), expected);
      expect(smbConfigIdOf(uri), configId);
    }

    test('share root', () => roundTrips('/', '/', asUri: 'smb://$configId'));

    test('single directory',
        () => roundTrips('books', 'books', asUri: 'smb://$configId/books'));

    test('nested directories', () => roundTrips(r'deep\a\b\c', r'deep\a\b\c'));

    test('spaces', () => roundTrips(r'books\sub dir', r'books\sub dir'));

    test('non-ASCII', () {
      roundTrips(r'books\作品集第2巻.pdf', r'books\作品集第2巻.pdf');
    });

    test('characters that mean something in a URI', () {
      roundTrips(r'a\b#c', r'a\b#c'); // fragment
      roundTrips(r'a\b?c', r'a\b?c'); // query
      roundTrips(r'a\b%c', r'a\b%c'); // percent-escape
      roundTrips(r'a\b&c=d', r'a\b&c=d');
      roundTrips(r'a\b+c', r'a\b+c');
    });

    test('a leading separator is dropped, as dart_smb2 does anyway', () {
      roundTrips(r'\leading', 'leading');
    });

    test('a forward-slash separator is accepted too', () {
      expect(smbPathOf(smbGalleryUri(configId, 'a/b')), r'a\b');
    });

    test('is not mistaken for a Pixiv URI', () {
      expect(isPixivFavoritesUri(smbGalleryUri(configId, 'x')), isFalse);
    });
  });

  group('Pixiv', () {
    void roundTrips(String path, {String? asUri}) {
      final uri = pixivGalleryUri(path);
      if (asUri != null) expect(uri.toString(), asUri);
      expect(pixivPathOf(Uri.parse(uri.toString())), path);
    }

    test('top', () => roundTrips('/top', asUri: 'pixiv:/top'));
    test('bookmarks', () => roundTrips('/bookmarks'));
    test('one author', () => roundTrips('/user/12345'));

    test('search keeps its options', () {
      roundTrips('/search?word=%E3%81%8B&s_mode=s_tag_full&order=date_d');
    });

    test('favorites is recognised as the locally seeded page', () {
      expect(isPixivFavoritesUri(pixivGalleryUri('/favorites')), isTrue);
      expect(isPixivFavoritesUri(pixivGalleryUri('/top')), isFalse);
      expect(isPixivFavoritesUri(pixivGalleryUri('/user/1')), isFalse);
    });

    test('smbConfigIdOf declines a Pixiv URI', () {
      expect(smbConfigIdOf(pixivGalleryUri('/top')), isNull);
    });
  });
}
