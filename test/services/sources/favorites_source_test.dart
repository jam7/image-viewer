import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/pixiv/pixiv_api_client.dart';
import 'package:image_viewer/services/pixiv/pixiv_web_client.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/favorites_source.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/pixiv_source.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/sources/source_registry.dart';

/// The favorites list holds items from every source, so the point of this
/// provider is what it does *not* do itself: an SMB favourite must keep being
/// an SMB item and be fetched by the SMB source.
void main() {
  late SourceRegistry registry;
  late _RecordingSource smb;
  late FavoritesSource favorites;

  setUp(() {
    registry = SourceRegistry(smbConfigStore: SmbConfigStore());
    smb = _RecordingSource();
    favorites = FavoritesSource(store: FavoritesStore(), registry: registry);
  });

  ImageSource smbItem() => ImageSource(
        id: 'smb:test:pic.jpg',
        name: 'pic.jpg',
        uri: 'smb://server/share/pic.jpg',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
      );

  test('a thumbnail is fetched by the source the item came from', () async {
    registry.register('smb:test', smb);

    final bytes = await favorites.fetchThumbnail(smbItem(), targetPx: 155);

    expect(smb.thumbnailIds, ['smb:test:pic.jpg']);
    expect(bytes, [7]);
  });

  test('an item whose source is not connected has none yet', () async {
    // Nothing registered: asking would mean connecting, and a background
    // thumbnail fetch must not put a login or a connection in the user's way.
    // "Not yet" rather than "never": the source may be connected later in the
    // same run, and asking again is a lookup in the registry (ADR 011).
    expect(
      () => favorites.fetchThumbnail(smbItem(), targetPx: 155),
      throwsA(isA<ThumbnailNotReadyException>()),
    );
  });

  test('pages are resolved by the owning source', () async {
    registry.register('smb:test', smb);

    await favorites.resolvePages(smbItem());

    expect(smb.resolvedIds, ['smb:test:pic.jpg']);
  });

  test('an unreachable source still yields the item itself as its page',
      () async {
    final pages = await favorites.resolvePages(smbItem());

    expect(pages.map((p) => p.id), ['smb:test:pic.jpg']);
  });

  test('cancelling reaches the connected sources, not itself', () {
    registry.register('smb:test', smb);
    // Registered alongside them, so cancelling must skip itself or recurse.
    registry.register('fav:default', favorites);

    favorites.cancelThumbnailWork();

    expect(smb.cancelCount, 1);
  });

  test('a Pixiv thumbnail URL that was re-issued is kept', () async {
    // The stored URL is this list's own copy, so correcting it is its job.
    final tempDir = Directory.systemTemp.createTempSync('fav_thumb_url');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = FavoritesStore();
    await store.init(baseDir: tempDir);
    await store.toggle('42', {
      'name': 'work',
      'uri': 'https://i.pximg.net/stale.jpg',
      'sourceKey': 'pixiv:default',
      'thumbnailUrl': 'https://i.pximg.net/stale.jpg',
      'type': 'pixiv',
    });

    final pixiv = _RefreshingPixivSource('https://i.pximg.net/fresh.jpg');
    registry.register('pixiv:default', pixiv);
    final source = FavoritesSource(store: store, registry: registry);

    final item = (await source.listImages()).single;
    await source.fetchThumbnail(item, targetPx: 155);
    await pumpEventQueue(); // the write-back is not awaited by the fetch

    expect(store.listAll().single.thumbnailUrl, 'https://i.pximg.net/fresh.jpg');
    // sourceInfo carries its own copy, which is what becomes the next
    // ImageSource; a stale one there would undo the fix.
    expect((await source.listImages()).single.metadata?['thumbnailUrl'],
        'https://i.pximg.net/fresh.jpg');
  });

  test('the registry hands back a registered source', () async {
    registry.register('fav:default', favorites);

    // resolve knows how to build Pixiv and SMB; everything else has to be
    // registered, and was not being looked for.
    expect(await registry.resolve('fav:default', _NoContext()), favorites);
    expect(registry.peek('fav:default'), favorites);
  });
}

/// resolve takes a BuildContext only to raise a login screen, which a
/// registered source never needs.
class _NoContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Stands in for the real 404-then-look-it-up path: reports a new URL the way
/// PixivSource does after re-asking the API.
class _RefreshingPixivSource extends PixivSource {
  final String freshUrl;

  _RefreshingPixivSource(this.freshUrl)
      : super(client: PixivApiClient(webClient: PixivWebClient()));

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source,
      {int targetPx = 155}) async {
    onThumbnailUrlRefreshed?.call(source.id, freshUrl);
    return Uint8List.fromList(const [7]);
  }
}

class _RecordingSource extends SmbSource {
  final List<String> thumbnailIds = [];
  final List<String> resolvedIds = [];
  int cancelCount = 0;

  _RecordingSource()
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
  Future<Uint8List> fetchThumbnail(ImageSource source,
      {int targetPx = 155}) async {
    thumbnailIds.add(source.id);
    return Uint8List.fromList(const [7]);
  }

  @override
  Future<List<ImageSource>> resolvePages(ImageSource source) async {
    resolvedIds.add(source.id);
    return [source];
  }

  @override
  void cancelThumbnailWork() => cancelCount++;
}
