import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';

/// Pins the default ImageSourceProvider.loadPage contract (ADR 007): finite
/// sources return all items in one page with nextCursor == null.
void main() {
  ImageSource img(String id) => ImageSource(
        id: id,
        name: id,
        uri: id,
        type: ImageSourceType.smb,
      );

  test('default loadPage wraps listImages as a single finite page', () async {
    final provider = _FiniteProvider([img('a'), img('b')]);

    final page = await provider.loadPage();

    expect(page.items.map((i) => i.id), ['a', 'b']);
    expect(page.nextCursor, isNull);
    expect(page.hasMore, isFalse);
  });

  test('default loadPage forwards the path to listImages', () async {
    final provider = _FiniteProvider(const []);

    await provider.loadPage(path: '/sub');

    expect(provider.lastPath, '/sub');
  });
}

/// Minimal finite provider using the default loadPage.
class _FiniteProvider extends ImageSourceProvider {
  final List<ImageSource> items;
  String? lastPath;
  _FiniteProvider(this.items);

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    lastPath = path;
    return items;
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source,
          {int targetPx = 155}) async =>
      Uint8List(0);

  @override
  Future<Uint8List> fetchFullImage(ImageSource source,
          {void Function(int received, int total)? onProgress}) async =>
      Uint8List(0);

  @override
  Future<void> dispose() async {}
}
