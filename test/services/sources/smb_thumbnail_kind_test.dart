import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';

/// fetchThumbnail picks a way to make one from the kind of file it is. Most of
/// those ways need a server; this is the one that answers before reaching it,
/// and the one whose answer the gallery treats specially (ADR 011).
void main() {
  SmbSource source() => SmbSource(
        config: const ServerConfig(
          id: 'test',
          name: 'test',
          type: ImageSourceType.smb,
          host: 'localhost',
        ),
        password: '',
      );

  ImageSource pdf() => ImageSource(
        id: 'smb:test:作品集第2巻.pdf',
        name: '作品集第2巻.pdf',
        uri: 'books\\作品集第2巻.pdf',
        type: ImageSourceType.smb,
        sourceKey: 'smb:test',
        metadata: const {'isPdf': true},
      );

  test('a PDF nobody has opened yet has no thumbnail yet', () {
    // Rendering page 0 needs the whole file, which the viewer caches on the
    // way in. Until then this is "not yet", not "never": the tile asks again
    // every time it is painted, and the cost of being wrong is one map lookup.
    expect(
      () => source().fetchThumbnail(pdf()),
      throwsA(isA<ThumbnailNotReadyException>()),
    );
  });
}
