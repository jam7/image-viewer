import 'dart:typed_data';

import 'keyed_file_store.dart';

/// L3: ユーザーが明示的にDLした画像の永久保存。
/// トグル式 — DL済みならtoggleで削除、未DLならtoggleで保存。
class DownloadStore extends KeyedFileStore {
  DownloadStore() : super(dirName: 'downloads');

  /// DL済みならtrue。
  bool isDownloaded(String key) => contains(key);

  /// [meta] は受け取るが保存していない。呼び出し側 (`viewer_screen._metaFor`)
  /// が毎回組み立てて捨てられている状態で、保存するか引数を消すかは未決
  /// (notes/TODO.md)。
  @override
  Future<void> put(String key, Uint8List data,
          [Map<String, dynamic>? meta]) =>
      super.put(key, data);

  /// トグル。未DL→保存してtrue返却、DL済み→削除してfalse返却。
  Future<bool> toggle(
      String key, Uint8List? data, Map<String, dynamic>? meta) async {
    if (!initialized) return false;
    if (contains(key)) {
      await remove(key);
      return false;
    }
    if (data == null) return false;
    await put(key, data, meta);
    return true;
  }

  /// Stream download: write chunks directly to file without holding all in memory.
  /// [isCancelled] is checked after each chunk; if true, deletes partial file.
  Future<bool> putFromStream(
    String key,
    Stream<Uint8List> stream,
    Map<String, dynamic>? meta, {
    void Function(int received, int total)? onProgress,
    int total = 0,
    bool Function()? isCancelled,
  }) async {
    if (!initialized) return false;

    final file = fileFor(key);
    final sink = file.openWrite();
    int received = 0;
    bool cancelled = false;
    try {
      await for (final chunk in stream) {
        if (isCancelled?.call() == true) {
          cancelled = true;
          break;
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (cancelled) {
      if (file.existsSync()) file.deleteSync();
      return false;
    }

    recordEntry(key, received);
    await saveIndex();
    return true;
  }
}
