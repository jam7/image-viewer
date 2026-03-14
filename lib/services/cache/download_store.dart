import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'cache_metadata.dart';

/// L3: ユーザーが明示的にDLした画像の永久保存。
/// トグル式 — DL済みならtoggleで削除、未DLならtoggleで保存。
class DownloadStore {
  late Directory _dlDir;
  final Map<String, CacheEntryMeta> _entries = {};
  int _totalSizeBytes = 0;
  bool _initialized = false;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _dlDir = Directory('${appDir.path}/cache/downloads');
    if (!_dlDir.existsSync()) {
      _dlDir.createSync(recursive: true);
    }
    await _loadMetadata();
    _initialized = true;
  }

  /// DL済みならtrue。
  bool isDownloaded(String key) {
    return _entries.containsKey(key);
  }

  /// トグル。未DL→保存してtrue返却、DL済み→削除してfalse返却。
  Future<bool> toggle(
      String key, Uint8List? data, Map<String, dynamic>? meta) async {
    if (!_initialized) return false;

    if (_entries.containsKey(key)) {
      // 削除
      final entry = _entries.remove(key)!;
      _totalSizeBytes -= entry.sizeBytes;
      final file = _fileFor(key);
      if (file.existsSync()) file.deleteSync();
      await _flushMetadata();
      return false;
    } else {
      // 保存
      if (data == null) return false;
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
      await _flushMetadata();
      return true;
    }
  }

  Future<Uint8List?> get(String key) async {
    if (!_initialized || !_entries.containsKey(key)) return null;
    final file = _fileFor(key);
    if (!file.existsSync()) {
      _entries.remove(key);
      return null;
    }
    return file.readAsBytes();
  }

  Future<CacheStats> getStats() async {
    return CacheStats(
      totalSizeBytes: _totalSizeBytes,
      itemCount: _entries.length,
      maxSizeBytes: -1, // 無制限
    );
  }

  Future<void> clear() async {
    if (!_initialized) return;
    _entries.clear();
    _totalSizeBytes = 0;
    if (_dlDir.existsSync()) {
      await _dlDir.delete(recursive: true);
      _dlDir.createSync(recursive: true);
    }
    await _flushMetadata();
  }

  // --- 内部メソッド ---

  File _fileFor(String key) {
    final hash = sha256.convert(utf8.encode(key)).toString();
    return File('${_dlDir.path}/$hash.bin');
  }

  Future<void> _flushMetadata() async {
    final metaFile = File('${_dlDir.path}/_metadata.json');
    final data = {
      'totalSizeBytes': _totalSizeBytes,
      'entries': {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      },
    };
    final tmpFile = File('${metaFile.path}.tmp');
    await tmpFile.writeAsString(jsonEncode(data), flush: true);
    await tmpFile.rename(metaFile.path);
  }

  Future<void> _loadMetadata() async {
    final metaFile = File('${_dlDir.path}/_metadata.json');
    if (!metaFile.existsSync()) return;

    try {
      final content = await metaFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final entries = data['entries'] as Map<String, dynamic>? ?? {};
      _entries.clear();
      _totalSizeBytes = 0;
      for (final entry in entries.entries) {
        final meta =
            CacheEntryMeta.fromJson(entry.value as Map<String, dynamic>);
        if (_fileFor(meta.key).existsSync()) {
          _entries[entry.key] = meta;
          _totalSizeBytes += meta.sizeBytes;
        }
      }
    } catch (_) {
      _entries.clear();
      _totalSizeBytes = 0;
    }
  }
}
