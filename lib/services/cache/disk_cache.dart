import 'keyed_file_store.dart';

/// L2キャッシュ: 圧縮済み画像をディスクに保持。
/// LRU + サイズ上限で排出。
class DiskCache extends KeyedFileStore {
  /// How long the index may be out of date on disk.
  ///
  /// Writing it costs about 90ms per ten thousand entries, on the app's own
  /// thread (measured on the device, 2026-08-02). It used to be written every
  /// fifth operation, which during a scroll over uncached pictures meant a
  /// 90ms stall every 150ms: the list moved three rows and stopped.
  ///
  /// The downloads store writes at once instead: what it would lose in this
  /// window is the record that the user asked to keep something, not a cache
  /// that refills itself.
  static const _flushDelay = Duration(seconds: 5);

  DiskCache({super.maxSizeBytes = 1024 * 1024 * 1024}) // デフォルト 1GB
      : super(dirName: 'l2', indexDelay: _flushDelay);
}
