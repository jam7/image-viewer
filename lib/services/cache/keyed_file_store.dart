import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'cache_metadata.dart';

/// A directory of files named after their keys, and an index of what is in it.
///
/// L2 (the cache) and L3 (what the user chose to keep) are this same store —
/// see [ADR 003](../../../docs/adr/003-cache-layers.md). Only two things
/// differ between them, and both are arguments here:
///
/// - [maxSizeBytes]: past the limit the least recently read entry goes.
///   [unlimited] keeps everything
/// - [indexDelay]: how far behind the files the index may fall. null writes it
///   before a mutating call returns
///
/// Everything else was written twice, which is how one copy came to have a
/// re-entrancy guard and a self-heal that the other lacked.
class KeyedFileStore {
  /// For [maxSizeBytes]: nothing is ever dropped to make room.
  static const unlimited = -1;

  final String _dirName;
  final Duration? _indexDelay;
  int _maxSizeBytes;

  late Directory _dir;
  final Map<String, CacheEntryMeta> _entries = {};
  int _totalSizeBytes = 0;
  bool _initialized = false;

  Timer? _flushTimer;
  bool _unwritten = false;
  bool _isFlushing = false;
  bool _needsFlush = false;

  /// Named after the subclass, so `l2` and the downloads stay apart in the log.
  late final Logger _log = Logger('$runtimeType');

  KeyedFileStore({
    required String dirName,
    int maxSizeBytes = unlimited,
    Duration? indexDelay,
  })  : _dirName = dirName,
        _maxSizeBytes = maxSizeBytes,
        _indexDelay = indexDelay;

  int get maxSizeBytes => _maxSizeBytes;

  /// Nothing before [init] answers anything: the guard subclasses share.
  bool get initialized => _initialized;

  /// [baseDir] overrides the app documents directory (tests only).
  Future<void> init({Directory? baseDir}) async {
    final appDir = baseDir ?? await getApplicationDocumentsDirectory();
    _dir = Directory('${appDir.path}/cache/$_dirName');
    if (!_dir.existsSync()) {
      _dir.createSync(recursive: true);
    }
    await _loadIndex();
    _initialized = true;
  }

  bool contains(String key) => _entries.containsKey(key);

  Future<Uint8List?> get(String key) async {
    final file = _validFile(key);
    return file?.readAsBytes();
  }

  /// キーに対応するファイルパスを返す。エントリが存在しファイルがあれば返す
  /// (読み取りは呼び出し側が行う)。アクセス時間は get と同様に更新する。
  String? getFilePath(String key) => _validFile(key)?.path;

  Future<void> put(String key, Uint8List data) async {
    if (!_initialized) return;
    _forget(key);
    await _evictIfNeeded(data.length);
    await fileFor(key).writeAsBytes(data, flush: true);
    recordEntry(key, data.length);
    await saveIndex();
  }

  Future<void> remove(String key) async {
    if (!_initialized) return;
    if (!_forget(key)) return;
    await saveIndex();
  }

  Future<void> clear() async {
    if (!_initialized) return;
    _entries.clear();
    _totalSizeBytes = 0;
    if (_dir.existsSync()) {
      await _dir.delete(recursive: true);
      _dir.createSync(recursive: true);
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
    unawaited(_evictIfNeeded(0));
    _flushSoon();
  }

  /// Write the index now, if anything is waiting to be written.
  ///
  /// For when the app is going away: [indexDelay] is a window in which being
  /// killed would lose what has been stored since the last write, leaving
  /// files on disk that nothing knows about and nothing counts towards the
  /// size limit.
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_unwritten) return;
    await _writeIndex();
  }

  // --- サブクラス向け ---

  File fileFor(String key) {
    final hash = sha256.convert(utf8.encode(key)).toString();
    return File('${_dir.path}/$hash.bin');
  }

  /// The file for [key] is written and this many bytes long.
  void recordEntry(String key, int sizeBytes) {
    final now = DateTime.now();
    _entries[key] = CacheEntryMeta(
      key: key,
      sizeBytes: sizeBytes,
      lastAccessTime: now,
      createdTime: now,
    );
    _totalSizeBytes += sizeBytes;
  }

  /// After a change the caller is awaiting. Writes now or schedules, by
  /// [indexDelay].
  Future<void> saveIndex() async {
    if (_indexDelay == null) {
      await _writeIndex();
      return;
    }
    _flushSoon();
  }

  // --- 内部メソッド ---

  /// エントリと実ファイルの存在を検証し、アクセス時間を更新してファイルを返す。
  /// ファイルが消えていた場合はエントリとサイズ集計から取り除く (自己修復)。
  File? _validFile(String key) {
    if (!_initialized) return null;
    final entry = _entries[key];
    if (entry == null) return null;

    final file = fileFor(key);
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

  /// Drop the entry and its file, leaving the index unwritten: every caller
  /// goes on to either write a new entry or save. Returns whether there was
  /// anything to drop.
  bool _forget(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return false;
    _totalSizeBytes -= entry.sizeBytes;
    try {
      final file = fileFor(key);
      if (file.existsSync()) file.deleteSync();
    } catch (e, st) {
      _log.warning('delete error for $key', e, st);
    }
    return true;
  }

  Future<void> _evictIfNeeded(int incomingBytes) async {
    if (_maxSizeBytes <= 0) return;
    while (_totalSizeBytes + incomingBytes > _maxSizeBytes &&
        _entries.isNotEmpty) {
      // LRU: 最もアクセスが古いエントリを削除
      final oldest = _entries.values.reduce(
        (a, b) => a.lastAccessTime.isBefore(b.lastAccessTime) ? a : b,
      );
      _forget(oldest.key);
    }
  }

  /// The index itself changed: write it, within [indexDelay] and once for
  /// however many changes arrive in that time. A store that writes at once
  /// ([indexDelay] null) has no timer, so this only marks; what marked it was
  /// a self-heal, and the next real change carries it out.
  void _flushSoon() {
    _unwritten = true;
    final delay = _indexDelay;
    if (delay == null) return;
    _flushTimer ??= Timer(delay, () {
      _flushTimer = null;
      if (_unwritten) unawaited(_writeIndex());
    });
  }

  /// Only an access time moved. Worth writing eventually, since it is the
  /// order things are dropped in, but never worth a write of its own: reading
  /// cached pictures would then stall every few seconds for nothing anyone
  /// asked for. It goes out with the next real change, or on the way out.
  void _touched() => _unwritten = true;

  Future<void> _writeIndex() async {
    if (_isFlushing) {
      _needsFlush = true;
      return;
    }
    _isFlushing = true;
    _unwritten = false;

    try {
      final metaFile = File('${_dir.path}/_metadata.json');
      final encoded = _encodeIndex();
      final tmpFile = File('${metaFile.path}.tmp');
      await tmpFile.writeAsString(encoded, flush: true);
      await tmpFile.rename(metaFile.path);
    } catch (e, st) {
      // rename失敗時は次回のflushで再試行
      _log.warning('index write error', e, st);
      _needsFlush = true;
    } finally {
      _isFlushing = false;
      if (_needsFlush) {
        _needsFlush = false;
        unawaited(_writeIndex());
      }
    }
  }

  /// Timed because it is the one thing here that runs whole on the app's own
  /// thread: every entry becomes a map and the lot is encoded. A frame is
  /// 16ms. What keeps it out of the way is how rarely it now happens
  /// ([indexDelay]), not how long it takes.
  String _encodeIndex() {
    final spent = Stopwatch()..start();
    final encoded = jsonEncode({
      'maxSizeBytes': _maxSizeBytes,
      'totalSizeBytes': _totalSizeBytes,
      'entries': {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      },
    });
    spent.stop();
    if (spent.elapsedMilliseconds >= 8) {
      _log.info('metadata: ${_entries.length} entries encoded in '
          '${spent.elapsedMilliseconds}ms (${encoded.length ~/ 1024}KB)');
    }
    return encoded;
  }

  Future<void> _loadIndex() async {
    final metaFile = File('${_dir.path}/_metadata.json');
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
        if (fileFor(meta.key).existsSync()) {
          _entries[entry.key] = meta;
          _totalSizeBytes += meta.sizeBytes;
        }
      }
    } catch (e, st) {
      _log.warning('index load error', e, st);
      _entries.clear();
      _totalSizeBytes = 0;
    }
  }
}
