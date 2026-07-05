import 'dart:typed_data';

import '../../models/image_source.dart';

/// 画像取得の共通インターフェース。
/// 各プロトコル（HTTP, SMB, Google Drive, OneDrive）がこれを実装する。
abstract class ImageSourceProvider {
  /// 画像一覧を取得する。
  Future<List<ImageSource>> listImages({String? path});

  /// サムネイルを取得する。cheaply に生成できない場合は
  /// [ThumbnailNotSupportedException] を throw する (例: 未 DL の PDF、画像の
  /// 無い ZIP)。呼び出し側 (ThumbnailLoader) が失敗結果に変換する。
  Future<Uint8List> fetchThumbnail(ImageSource source);

  /// 進行中のサムネイル生成を中断し、重いリソースを解放する。
  /// ThumbnailLoader.cancel() から呼ばれる (例: 動画再生前に SMB 接続と
  /// media_kit プレーヤを解放する)。既定は何もしない。
  void cancelThumbnailWork() {}

  /// フル解像度の画像を取得する。
  /// [onProgress] でダウンロード進捗を通知。
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  });

  /// Stream the raw file bytes (for large file download to disk).
  /// Returns the stream, file size, and a close callback to release resources.
  /// Default wraps fetchFullImage.
  Future<({Stream<Uint8List> stream, int fileSize, Future<void> Function() close})> openReadStream(
    ImageSource source,
  ) async {
    final data = await fetchFullImage(source);
    return (stream: Stream.value(data), fileSize: data.length, close: () async {});
  }

  /// 作品のページ一覧を解決する。
  /// Pixiv: 複数ページ作品を展開。SMB: そのまま返す。
  Future<List<ImageSource>> resolvePages(ImageSource source) async => [source];

  /// リソースを解放する。
  Future<void> dispose();
}

/// Thrown by [ImageSourceProvider.fetchThumbnail] when a thumbnail cannot be
/// produced cheaply for this item (e.g. an uncached PDF, a ZIP with no images).
class ThumbnailNotSupportedException implements Exception {
  final String message;
  ThumbnailNotSupportedException(this.message);
  @override
  String toString() => 'ThumbnailNotSupportedException: $message';
}
