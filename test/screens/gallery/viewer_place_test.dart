import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/models/smb_identity.dart';
import 'package:image_viewer/screens/gallery/gallery_session.dart';
import 'package:image_viewer/screens/gallery/gallery_tab.dart';
import 'package:image_viewer/screens/gallery/gallery_uri.dart';
import 'package:image_viewer/screens/gallery/gallery_uri_dialect.dart';
import 'package:image_viewer/screens/gallery/viewer_gallery_body.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';

/// The viewer as a place (ADR 010): an address that names one work, and a
/// neighbourhood read off the tab rather than carried in the address.
void main() {
  late Directory tempDir;
  late CacheManager cache;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('viewer_place');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 20), l2: l2, l3: l3);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ImageSource pixivWork(String id) => ImageSource(
        id: id,
        name: 'work$id',
        uri: '',
        type: ImageSourceType.pixiv,
        sourceKey: 'pixiv:default',
        metadata: {'illustId': int.parse(id)},
      );

  ImageSource smbFile(String path, {bool dir = false, bool video = false}) =>
      ImageSource(
        id: smbItemId('1700000000000', path),
        name: path.split(r'\').last,
        uri: path,
        type: ImageSourceType.smb,
        sourceKey: 'smb:1700000000000',
        metadata: {'isDirectory': dir, 'isVideo': video, 'path': path},
      );

  group('an address that names one thing', () {
    test('a Pixiv work reads back as the item the listing would make', () {
      final item = itemOf(pixivArtworkUri('456'))!;
      expect(item.id, pixivWork('456').id);
      expect(item.metadata?['illustId'], 456);
    });

    test('an SMB file too, id and all', () {
      // The id has to match what listImages builds, since that is how the
      // viewer finds itself in the list it was opened from. Both spell it
      // through smbItemId now, so this pins the spelling rather than the
      // agreement between two copies of it.
      final uri = smbFileUri('1700000000000', r'books\vol2\a.jpg');
      expect(itemOf(uri)!.id, smbItemId('1700000000000', r'books\vol2\a.jpg'));
      expect(itemOf(uri)!.id, smbFile(r'books\vol2\a.jpg').id);
    });

    test('a list is not one thing', () {
      for (final uri in [
        pixivGalleryUri('/top'),
        pixivGalleryUri('/user/1700000000000'),
        smbGalleryUri('1700000000000', 'books'), // a directory
        homeGalleryUri(),
        favGalleryUri(),
      ]) {
        expect(itemOf(uri), isNull, reason: '$uri');
      }
    });

    test('a dot in a folder name does not make it a file', () {
      // "Has a dot" was the first rule here, and it put the viewer where a
      // listing belongs the moment a folder was named like this.
      expect(itemOf(smbGalleryUri('1700000000000', 'vol2.5')), isNull);
      // Even one the app can open: the trailing slash settles it outright.
      expect(itemOf(smbGalleryUri('1700000000000', 'test.jpg')), isNull);
      expect(placeOf(smbFile('vol2.5', dir: true)), isNull);
      // And an extension the app cannot open is not something to look at.
      expect(itemOf(smbFileUri('1700000000000', r'books\a.txt')), isNull);
    });

    test('and it says what kind of thing, as the listing would', () {
      // The viewer asks the metadata what to open with. Arriving from a list
      // it is handed the listed item, which carries the answer; an address
      // pasted from somewhere else has no list behind it, and a video taken
      // for a picture is fetched whole into memory before anything else can
      // go wrong with it.
      final movie = itemOf(smbFileUri('1700000000000', r'books\movie.mp4'));
      expect(movie?.metadata?['isVideo'], isTrue);
      final book = itemOf(smbFileUri('1700000000000', r'books\book.zip'));
      expect(book?.metadata?['isZip'], isTrue);
      final pdf = itemOf(smbFileUri('1700000000000', r'books\book.pdf'));
      expect(pdf?.metadata?['isPdf'], isTrue);
      // A picture is the plain case and says nothing beyond being a file.
      final picture = itemOf(smbFileUri('1700000000000', r'books\a.jpg'));
      expect(picture?.metadata?['isDirectory'], isFalse);
      expect(picture?.metadata?.containsKey('isVideo'), isFalse);
    });

    test('and the address goes back the way it came', () {
      expect(placeOf(pixivWork('456')), pixivArtworkUri('456'));
      expect(placeOf(smbFile(r'books\vol2\a.jpg')),
          smbFileUri('1700000000000', r'books\vol2\a.jpg'));
    });

    test('a directory is a list, and has no address of this kind', () {
      expect(placeOf(smbFile('books', dir: true)), isNull);
    });

    test('a video is one of the things to look at', () {
      // Which is what lets a folder of films and pictures be swiped through
      // as one list (ADR 010 段階 6).
      expect(placeOf(smbFile(r'books\movie.mp4', video: true)),
          smbFileUri('1700000000000', r'books\movie.mp4'));
    });
  });

  group('an address that turns out to be a list', () {
    test('SMB can say where the listing is', () {
      // Only an outside address can be wrong this way, and only the server can
      // settle it — so when it does, there has to be somewhere to go.
      expect(listAt(smbFileUri('1700000000000', 'test.jpg')),
          smbGalleryUri('1700000000000', 'test.jpg'));
    });

    test('a source that cannot make the mistake says nothing', () {
      // A Pixiv work id is not a page id; the shapes cannot be confused.
      expect(listAt(pixivArtworkUri('456')), isNull);
    });
  });

  group('the neighbourhood', () {
    GallerySession listOf(List<ImageSource> items) => GallerySession(
          sourceUri: pixivGalleryUri('/top'),
          provider: _Fake(items),
          cacheManager: cache,
        );

    Future<GalleryTab> tabShowing(List<ImageSource> items, int at) async {
      final list = listOf(items);
      await list.loadNextPage();
      final tab = GalleryTab(list);
      tab.navigate(GallerySession.fromUri(
        placeOf(items[at])!,
        provider: list.provider,
        cacheManager: cache,
      ));
      return tab;
    }

    test('is the list the viewer was opened from', () async {
      final works = [pixivWork('1'), pixivWork('2'), pixivWork('3')];
      final tab = await tabShowing(works, 1);

      final here = neighbourhood(tab, itemOf(tab.current.sourceUri)!);

      expect(here.items.length, 3);
      expect(here.index, 1);
    });

    test('is the work alone when the tab has nothing behind it', () async {
      // Pasting an address into a new tab. There is no list to move along, and
      // inventing one would be worse than having none.
      final tab = GalleryTab(GallerySession.fromUri(
        pixivArtworkUri('456'),
        provider: _Fake(const []),
        cacheManager: cache,
      ));

      final here = neighbourhood(tab, itemOf(tab.current.sourceUri)!);

      expect(here.items.single.id, '456');
      expect(here.index, 0);
    });

    test('is the work alone when what is behind does not contain it', () async {
      // The tab was on an unrelated list and an address was pasted over it.
      final tab = await tabShowing([pixivWork('1'), pixivWork('2')], 0);
      tab.replaceCurrent(GallerySession.fromUri(
        pixivArtworkUri('999'),
        provider: _Fake(const []),
        cacheManager: cache,
      ));

      final here = neighbourhood(tab, itemOf(tab.current.sourceUri)!);

      expect(here.items.single.id, '999');
    });

    test('leaves out what cannot be looked at, and keeps what can', () async {
      // Swiping onto a directory would be a move to nowhere; swiping onto a
      // video is the point of the videos being here at all.
      final items = [
        smbFile('books', dir: true),
        smbFile(r'books\a.jpg'),
        smbFile(r'books\movie.mp4', video: true),
        smbFile(r'books\pic.jpg'),
      ];
      final tab = await tabShowing(items, 1);

      final here = neighbourhood(tab, itemOf(tab.current.sourceUri)!);

      expect(here.items.map((i) => i.name), ['a.jpg', 'movie.mp4', 'pic.jpg']);
      expect(here.index, 0);
    });

    test('narrowing the list narrows what can be swiped to', () async {
      // The filter is on the place now, so the viewer sees the same list the
      // grid does — it cannot swipe into what the grid is hiding.
      final works = [pixivWork('1'), pixivWork('2'), pixivWork('3')];
      works[1].metadata!['pageCount'] = 5;
      final tab = await tabShowing(works, 1);
      tab.history.first.minPageCount = 3;

      final here = neighbourhood(tab, itemOf(tab.current.sourceUri)!);

      expect(here.items.single.id, '2');
    });
  });
}

class _Fake extends SmbSource {
  final List<ImageSource> items;

  _Fake(this.items)
      : super(
          config: const ServerConfig(
            id: 'test',
            name: 'test',
            type: ImageSourceType.smb,
            host: 'localhost',
          ),
          password: '',
        );

  @override
  Future<PageResult> loadPage({String? path, Object? cursor}) async =>
      PageResult(items: items);

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async =>
      throw ThumbnailNotSupportedException('none');
}
