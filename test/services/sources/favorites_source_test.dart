import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/services/favorites/favorites_store.dart';
import 'package:image_viewer/services/smb/smb_config_store.dart';
import 'package:image_viewer/services/sources/favorites_source.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
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

    final bytes = await favorites.fetchThumbnail(smbItem());

    expect(smb.thumbnailIds, ['smb:test:pic.jpg']);
    expect(bytes, [7]);
  });

  test('an item whose source is not connected reports no thumbnail', () async {
    // Nothing registered: asking would mean connecting, and a background
    // thumbnail fetch must not put a login or a connection in the user's way.
    expect(
      () => favorites.fetchThumbnail(smbItem()),
      throwsA(isA<ThumbnailNotSupportedException>()),
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

  test('cancelling reaches the connected sources', () {
    registry.register('smb:test', smb);

    favorites.cancelThumbnailWork();

    expect(smb.cancelCount, 1);
  });
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
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
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
