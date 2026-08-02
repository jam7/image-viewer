import 'dart:ui' show Size;
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
  /// [targetPx] is the long edge the result will be drawn at, in device
  /// pixels (ADR 012). A source that already holds a compressed picture may
  /// return it unchanged when it is no larger than that; one that has to make
  /// the picture — a PDF page — should make it at that size and no bigger.
  Future<Uint8List> fetchThumbnail(ImageSource source, {required int targetPx});

  /// 進行中のサムネイル生成を中断し、重いリソースを解放する。
  /// ThumbnailLoader.cancel() から呼ばれる (例: 動画再生前に SMB 接続と
  /// media_kit プレーヤを解放する)。既定は何もしない。
  void cancelThumbnailWork() {}

  /// フル解像度の画像を取得する。
  /// [onProgress] でダウンロード進捗を通知。
  ///
  /// [maxDisplayPx] is the largest the result will be drawn, in device pixels,
  /// or null when the caller does not know. **Only a source that has to make
  /// the picture uses it** — a PDF page, which is drawing instructions until
  /// somebody chooses a resolution (ADR 012). Sources that already hold a
  /// compressed picture return it as it is; shrinking it here would throw away
  /// detail that costs nothing to keep, and the decoder is told the display
  /// size separately.
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
    Size? maxDisplayPx,
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

/// Thrown by [ImageSourceProvider.fetchThumbnail] when nothing can be made of
/// this item, and nothing will change that: a ZIP with no pictures, a PDF that
/// would not render, a video with no proxy to stream it through.
///
/// The answer is kept for as long as the app runs. Say
/// [ThumbnailNotReadyException] instead if the material might turn up.
class ThumbnailNotSupportedException implements Exception {
  final String message;
  ThumbnailNotSupportedException(this.message);
  @override
  String toString() => 'ThumbnailNotSupportedException: $message';
}

/// Thrown by [ImageSourceProvider.fetchThumbnail] when the material is not
/// there *yet* — an unopened PDF, a favourite whose source is not connected.
///
/// The difference from [ThumbnailNotSupportedException] is what happens next:
/// this answer is provisional, so it is asked again every time the tile is
/// painted. **Only throw it where finding out costs nothing** — a lookup, not
/// a read over the network. Anything expensive would then be paid for on every
/// scroll past.
class ThumbnailNotReadyException implements Exception {
  final String message;
  ThumbnailNotReadyException(this.message);
  @override
  String toString() => 'ThumbnailNotReadyException: $message';
}
