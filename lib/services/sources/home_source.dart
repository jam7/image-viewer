import 'dart:typed_data';

import '../../models/image_source.dart';
import 'image_source_provider.dart';

/// The landing page as a source, so it can be a tab like everywhere else.
///
/// It lists nothing: home shows the services and servers you can go to, not
/// items, and its body renders that itself rather than through a grid. The
/// provider exists because a tab is a stack of sessions and a session names the
/// source it looks at — home's answer is "nothing to page through".
class HomeSource extends ImageSourceProvider {
  @override
  Future<List<ImageSource>> listImages({String? path}) async => const [];

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) =>
      throw ThumbnailNotSupportedException('home has no items');

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) =>
      throw UnsupportedError('home has no items');

  @override
  Future<void> dispose() async {}
}
