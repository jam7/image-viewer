import 'dart:typed_data';

import '../../models/image_source.dart';
import 'image_source_provider.dart';

/// Google Drive経由の画像取得。
class GoogleDriveSource implements ImageSourceProvider {
  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    // TODO: 実装
    return [];
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    // TODO: 実装
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) async {
    // TODO: 実装
    throw UnimplementedError();
  }

  @override
  Future<void> dispose() async {}
}
