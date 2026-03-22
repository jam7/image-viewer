import 'dart:typed_data';

import '../../models/image_source.dart';

/// 画像取得の共通インターフェース。
/// 各プロトコル（HTTP, SMB, Google Drive, OneDrive）がこれを実装する。
abstract class ImageSourceProvider {
  /// 画像一覧を取得する。
  Future<List<ImageSource>> listImages({String? path});

  /// サムネイルを取得する。
  Future<Uint8List> fetchThumbnail(ImageSource source);

  /// フル解像度の画像を取得する。
  /// [onProgress] でダウンロード進捗を通知。
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  });

  /// Stream the raw file bytes (for large file download to disk).
  /// Returns the stream and file size. Default wraps fetchFullImage.
  Future<({Stream<Uint8List> stream, int fileSize})> openReadStream(
    ImageSource source,
  ) async {
    final data = await fetchFullImage(source);
    return (stream: Stream.value(data), fileSize: data.length);
  }

  /// 作品のページ一覧を解決する。
  /// Pixiv: 複数ページ作品を展開。SMB: そのまま返す。
  Future<List<ImageSource>> resolvePages(ImageSource source) async => [source];

  /// リソースを解放する。
  Future<void> dispose();
}
