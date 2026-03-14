import 'dart:typed_data';

/// L1キャッシュ: デコード済み画像をメモリに保持。
/// LRU + 現在位置からの距離で排出。
class MemoryCache {
  final int maxEntries;
  final Map<String, Uint8List> _cache = {};
  final List<String> _accessOrder = [];

  MemoryCache({this.maxEntries = 5});

  Uint8List? get(String key) {
    if (!_cache.containsKey(key)) return null;
    _accessOrder.remove(key);
    _accessOrder.add(key);
    return _cache[key];
  }

  void put(String key, Uint8List data) {
    if (_cache.containsKey(key)) {
      _accessOrder.remove(key);
    } else if (_cache.length >= maxEntries) {
      final evictKey = _accessOrder.removeAt(0);
      _cache.remove(evictKey);
    }
    _cache[key] = data;
    _accessOrder.add(key);
  }

  void clear() {
    _cache.clear();
    _accessOrder.clear();
  }

  int get length => _cache.length;
}
