import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'cache_metadata.dart';

/// L2キャッシュ: 圧縮済み画像をディスクに保持。
/// LRU + サイズ上限で排出。
class DiskCache {
  int _maxSizeBytes;
  late Directory _cacheDir;
  final Map<String, CacheEntryMeta> _entries = {};
  int _totalSizeBytes = 0;
  int _opsSinceLastFlush = 0;
  bool _initialized = false;
  bool _isFlushing = false;
  bool _needsFlush = false;

  DiskCache({int maxSizeBytes = 1024 * 1024 * 1024}) // デフォルト 1GB
      : _maxSizeBytes = maxSizeBytes;

  int get maxSizeBytes => _maxSizeBytes;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/cache/l2');
    if (!_cacheDir.existsSync()) {
      _cacheDir.createSync(recursive: true);
    }
    await _loadMetadata();
    _initialized = true;
  }

  Future<Uint8List?> get(String key) async {
    if (!_initialized) return null;
    final entry = _entries[key];
    if (entry == null) return null;

    final file = _fileFor(key);
    if (!file.existsSync()) {
      _entries.remove(key);
      _totalSizeBytes -= entry.sizeBytes;
      _scheduleFlush();
      return null;
    }

    // アクセス時間を更新
    _entries[key] = entry.copyWith(lastAccessTime: DateTime.now());
    _scheduleFlush();

    return file.readAsBytes();
  }

  Future<void> put(String key, Uint8List data) async {
    if (!_initialized) return;

    // 既存エントリがあれば削除
    final existing = _entries[key];
    if (existing != null) {
      _totalSizeBytes -= existing.sizeBytes;
      _fileFor(key).deleteSync();
    }

    // 容量確保のためevict
    await _evictIfNeeded(data.length);

    // ファイル書き込み
    final file = _fileFor(key);
    await file.writeAsBytes(data, flush: true);

    final now = DateTime.now();
    _entries[key] = CacheEntryMeta(
      key: key,
      sizeBytes: data.length,
      lastAccessTime: now,
      createdTime: now,
    );
    _totalSizeBytes += data.length;
    _scheduleFlush();
  }

  Future<void> clear() async {
    if (!_initialized) return;
    _entries.clear();
    _totalSizeBytes = 0;
    if (_cacheDir.existsSync()) {
      await _cacheDir.delete(recursive: true);
      _cacheDir.createSync(recursive: true);
    }
    await _flushMetadata();
  }

  Future<CacheStats> getStats() async {
    return CacheStats(
      totalSizeBytes: _totalSizeBytes,
      itemCount: _entries.length,
      maxSizeBytes: _maxSizeBytes,
    );
  }

  void setMaxSize(int bytes) {
    _maxSizeBytes = bytes;
    _evictIfNeeded(0);
    _scheduleFlush();
  }

  // --- 内部メソッド ---

  File _fileFor(String key) {
    final hash = sha256.convert(utf8.encode(key)).toString();
    return File('${_cacheDir.path}/$hash.bin');
  }

  Future<void> _evictIfNeeded(int incomingBytes) async {
    while (_totalSizeBytes + incomingBytes > _maxSizeBytes &&
        _entries.isNotEmpty) {
      // LRU: 最もアクセスが古いエントリを削除
      final oldest = _entries.values.reduce(
        (a, b) => a.lastAccessTime.isBefore(b.lastAccessTime) ? a : b,
      );
      final file = _fileFor(oldest.key);
      if (file.existsSync()) {
        file.deleteSync();
      }
      _totalSizeBytes -= oldest.sizeBytes;
      _entries.remove(oldest.key);
    }
  }

  void _scheduleFlush() {
    _opsSinceLastFlush++;
    if (_opsSinceLastFlush >= 5) {
      _opsSinceLastFlush = 0;
      _flushMetadata();
    }
  }

  Future<void> _flushMetadata() async {
    if (_isFlushing) {
      _needsFlush = true;
      return;
    }
    _isFlushing = true;

    try {
      final metaFile = File('${_cacheDir.path}/_metadata.json');
      final data = {
        'maxSizeBytes': _maxSizeBytes,
        'totalSizeBytes': _totalSizeBytes,
        'entries': {
          for (final e in _entries.entries) e.key: e.value.toJson(),
        },
      };
      final tmpFile = File('${metaFile.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(metaFile.path);
    } catch (_) {
      // rename失敗時は次回のflushで再試行
      _needsFlush = true;
    } finally {
      _isFlushing = false;
      if (_needsFlush) {
        _needsFlush = false;
        unawaited(_flushMetadata());
      }
    }
  }

  Future<void> _loadMetadata() async {
    final metaFile = File('${_cacheDir.path}/_metadata.json');
    if (!metaFile.existsSync()) return;

    try {
      final content = await metaFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      _maxSizeBytes = data['maxSizeBytes'] as int? ?? _maxSizeBytes;
      final entries = data['entries'] as Map<String, dynamic>? ?? {};
      _entries.clear();
      _totalSizeBytes = 0;
      for (final entry in entries.entries) {
        final meta =
            CacheEntryMeta.fromJson(entry.value as Map<String, dynamic>);
        // ファイルが存在する場合のみ復元
        if (_fileFor(meta.key).existsSync()) {
          _entries[entry.key] = meta;
          _totalSizeBytes += meta.sizeBytes;
        }
      }
    } catch (_) {
      // メタデータ破損時はリセット
      _entries.clear();
      _totalSizeBytes = 0;
    }
  }
}
