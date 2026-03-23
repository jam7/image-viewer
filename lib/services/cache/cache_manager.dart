import 'dart:typed_data';

import 'cache_metadata.dart';
import 'disk_cache.dart';
import 'download_store.dart';
import 'memory_cache.dart';

/// 3層キャッシュの統合マネージャー。
/// 検索順: L1(メモリ) → L2(ディスク) → L3(DL) → ネットワーク。
class CacheManager {
  final MemoryCache l1;
  final DiskCache l2;
  final DownloadStore l3;

  CacheManager({
    required this.l1,
    required this.l2,
    required this.l3,
  });

  /// キーに対応するキャッシュファイルのパスを返す（L2 → L3 の順）。
  /// L1 はメモリなのでスキップ。
  String? getFilePath(String key) {
    // L2: ディスク
    final l2Path = l2.getFilePath(key);
    if (l2Path != null) return l2Path;

    // L3: DL
    final l3Path = l3.getFilePath(key);
    if (l3Path != null) return l3Path;

    return null;
  }

  /// キャッシュから取得。見つからなければ null。
  Future<CacheResult?> get(String key) async {
    // L1: メモリ
    final memData = l1.get(key);
    if (memData != null) {
      return CacheResult(memData, CacheSource.memory);
    }

    // L2: ディスク
    final diskData = await l2.get(key);
    if (diskData != null) {
      l1.put(key, diskData); // L1に昇格
      return CacheResult(diskData, CacheSource.disk);
    }

    // L3: DL
    final dlData = await l3.get(key);
    if (dlData != null) {
      l1.put(key, dlData); // L1に昇格
      return CacheResult(dlData, CacheSource.download);
    }

    return null;
  }

  /// ネットワークから取得し、L1 + L2 に格納。
  Future<CacheResult> fetchAndCache(
    String key,
    Future<Uint8List> Function() fetcher, {
    void Function(int received, int total)? onProgress,
  }) async {
    final data = await fetcher();
    l1.put(key, data);
    await l2.put(key, data);
    return CacheResult(data, CacheSource.network);
  }

  /// L2の統計。
  Future<CacheStats> getL2Stats() => l2.getStats();

  /// L3の統計。
  Future<CacheStats> getL3Stats() => l3.getStats();

  /// L2をクリア。
  Future<void> clearL2() async {
    l1.clear();
    await l2.clear();
  }

  /// L3をクリア。
  Future<void> clearL3() => l3.clear();

  /// L2のサイズ上限を変更。
  void setL2MaxSize(int bytes) => l2.setMaxSize(bytes);
}
