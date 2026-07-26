import 'dart:typed_data';

import '../../models/image_source.dart';

/// 画像取得の共通インターフェース。
/// 各プロトコル（HTTP, SMB, Google Drive, OneDrive）がこれを実装する。
abstract class ImageSourceProvider {
  /// 画像一覧を取得する。
  Future<List<ImageSource>> listImages({String? path});

  /// 1 ページ分のアイテムを取得する (仮想化ギャラリーの遅延ページ列。ADR 007)。
  ///
  /// [cursor] は不透明で、各ソースが解釈する (null = 先頭ページ)。有限ソース
  /// (ディレクトリ・お気に入り) は全件を 1 ページで返し `nextCursor == null`。
  /// ページネーションするソース (Pixiv 検索等) は続きを表す `nextCursor` を返す。
  /// 既定実装は [listImages] を 1 ページとして包む (有限扱い)。
  Future<PageResult> loadPage({String? path, Object? cursor}) async {
    final items = await listImages(path: path);
    return PageResult(items: items);
  }

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

/// One page of items from a paged source (ADR 007). [nextCursor] is null at the
/// end of the list. [total] is the total item count when the source knows it
/// (may be null / unknown, e.g. some Pixiv listings).
class PageResult {
  final List<ImageSource> items;
  final Object? nextCursor;
  final int? total;
  const PageResult({required this.items, this.nextCursor, this.total});

  bool get hasMore => nextCursor != null;
}

/// What was asked for as one thing to look at turned out to be a list.
///
/// Only an address that arrived from outside can be wrong this way: the app's
/// own addresses say which they are (ADR 010). Raised so the caller can go to
/// the list instead of showing a failure — and raised only when the source
/// actually said so, never on a read that merely failed.
class NotAnItemException implements Exception {
  final String path;
  NotAnItemException(this.path);
  @override
  String toString() => 'NotAnItemException: $path is a list, not an item';
}

/// Thrown by [ImageSourceProvider.fetchThumbnail] when a thumbnail cannot be
/// produced cheaply for this item (e.g. an uncached PDF, a ZIP with no images).
class ThumbnailNotSupportedException implements Exception {
  final String message;
  ThumbnailNotSupportedException(this.message);
  @override
  String toString() => 'ThumbnailNotSupportedException: $message';
}
