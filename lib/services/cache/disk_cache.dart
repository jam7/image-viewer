import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'cache_metadata.dart';

final _log = Logger('DiskCache');

/// L2キャッシュ: 圧縮済み画像をディスクに保持。
/// LRU + サイズ上限で排出。
class DiskCache {
  int _maxSizeBytes;
  late Directory _cacheDir;
  final Map<String, CacheEntryMeta> _entries = {};
  int _totalSizeBytes = 0;
  bool _initialized = false;
  Timer? _flushTimer;
  bool _unwritten = false;

  /// How long the index may be out of date on disk.
  ///
  /// Writing it costs about 90ms per ten thousand entries, on the app's own
  /// thread (measured on the device, 2026-08-02). It used to be written every
  /// fifth operation, which during a scroll over uncached pictures meant a
  /// 90ms stall every 150ms: the list moved three rows and stopped.
  static const _flushDelay = Duration(seconds: 5);
  bool _isFlushing = false;
  bool _needsFlush = false;

  DiskCache({int maxSizeBytes = 1024 * 1024 * 1024}) // デフォルト 1GB
      : _maxSizeBytes = maxSizeBytes;

  int get maxSizeBytes => _maxSizeBytes;

  /// [baseDir] overrides the app documents directory (tests only).
  Future<void> init({Directory? baseDir}) async {
    final appDir = baseDir ?? await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/cache/l2');
    if (!_cacheDir.existsSync()) {
      _cacheDir.createSync(recursive: true);
    }
    await _loadMetadata();
    _initialized = true;
  }

  Future<Uint8List?> get(String key) async {
    final file = _touchValidFile(key);
    return file?.readAsBytes();
  }

  /// キーに対応するファイルパスを返す。エントリが存在しファイルがあれば返す
  /// (読み取りは呼び出し側が行う)。アクセス時間は get と同様に更新する。
  String? getFilePath(String key) => _touchValidFile(key)?.path;

  /// エントリと実ファイルの存在を検証し、アクセス時間を更新してファイルを返す。
  /// ファイルが消えていた場合はエントリとサイズ集計から取り除く (自己修復)。
  File? _touchValidFile(String key) {
    if (!_initialized) return null;
    final entry = _entries[key];
    if (entry == null) return null;

    final file = _fileFor(key);
    if (!file.existsSync()) {
      _entries.remove(key);
      _totalSizeBytes -= entry.sizeBytes;
      _flushSoon();
      return null;
    }

    _entries[key] = entry.copyWith(lastAccessTime: DateTime.now());
    _touched();
    return file;
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
    _flushSoon();
  }

  /// Delete a single entry by key.
  void delete(String key) {
    if (!_initialized) return;
    final existing = _entries.remove(key);
    if (existing != null) {
      _totalSizeBytes -= existing.sizeBytes;
      try {
        _fileFor(key).deleteSync();
      } catch (e, st) {
        _log.warning('delete error for $key', e, st);
      }
      _flushSoon();
    }
  }

  Future<void> clear() async {
    if (!_initialized) return;
    _entries.clear();
    _totalSizeBytes = 0;
    if (_cacheDir.existsSync()) {
      await _cacheDir.delete(recursive: true);
      _cacheDir.createSync(recursive: true);
    }
    _unwritten = true;
    await flushNow();
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
    _flushSoon();
  }

  /// Write the index now, if anything is waiting to be written.
  ///
  /// For when the app is going away: [_flushDelay] is a window in which being
  /// killed would lose what has been cached since the last write, leaving
  /// files on disk that nothing knows about and nothing counts towards the
  /// size limit.
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_unwritten) return;
    await _flushMetadata();
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

  /// The index itself changed: write it, within [_flushDelay] and once for
  /// however many changes arrive in that time.
  void _flushSoon() {
    _unwritten = true;
    _flushTimer ??= Timer(_flushDelay, () {
      _flushTimer = null;
      if (_unwritten) unawaited(_flushMetadata());
    });
  }

  /// Only an access time moved. Worth writing eventually, since it is the
  /// order things are dropped in, but never worth a write of its own: reading
  /// cached pictures would then stall every few seconds for nothing anyone
  /// asked for. It goes out with the next real change, or on the way out.
  void _touched() => _unwritten = true;

  Future<void> _flushMetadata() async {
    if (_isFlushing) {
      _needsFlush = true;
      return;
    }
    _isFlushing = true;
    _unwritten = false;

    try {
      final metaFile = File('${_cacheDir.path}/_metadata.json');
      // Timed because it is the one thing here that runs whole on the app's
      // own thread: every entry becomes a map and the lot is encoded. A frame
      // is 16ms. What keeps it out of the way is how rarely it now happens
      // ([_flushDelay]), not how long it takes.
      final spent = Stopwatch()..start();
      final data = {
        'maxSizeBytes': _maxSizeBytes,
        'totalSizeBytes': _totalSizeBytes,
        'entries': {
          for (final e in _entries.entries) e.key: e.value.toJson(),
        },
      };
      final encoded = jsonEncode(data);
      spent.stop();
      if (spent.elapsedMilliseconds >= 8) {
        _log.info('metadata: ${_entries.length} entries encoded in '
            '${spent.elapsedMilliseconds}ms (${encoded.length ~/ 1024}KB)');
      }
      final tmpFile = File('${metaFile.path}.tmp');
      await tmpFile.writeAsString(encoded, flush: true);
      await tmpFile.rename(metaFile.path);
    } catch (e, st) {
      // rename失敗時は次回のflushで再試行
      _log.warning('flushMetadata error', e, st);
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
        final meta = CacheEntryMeta.fromJson(
            entry.value as Map<String, dynamic>, entry.key);
        // ファイルが存在する場合のみ復元
        if (_fileFor(meta.key).existsSync()) {
          _entries[entry.key] = meta;
          _totalSizeBytes += meta.sizeBytes;
        }
      }
    } catch (e, st) {
      _log.warning('metadata load error', e, st);
      _entries.clear();
      _totalSizeBytes = 0;
    }
  }
}
