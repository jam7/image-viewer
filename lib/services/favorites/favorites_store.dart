import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../cache/cache_metadata.dart';

final _log = Logger('FavoritesStore');

/// お気に入り: URLとメタデータのみ記録（画像データなし）。
/// トグル式 — お気に入り済みならtoggleで削除、未登録ならtoggleで追加。
class FavoritesStore {
  late File _file;
  final Map<String, FavoriteEntry> _entries = {};
  bool _initialized = false;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/cache');
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
    _file = File('${cacheDir.path}/favorites.json');
    await _load();
    _initialized = true;
  }

  bool isFavorite(String imageId) {
    return _entries.containsKey(imageId);
  }

  /// トグル。未登録→追加してtrue、登録済み→削除してfalse。
  Future<bool> toggle(String imageId, Map<String, dynamic> meta) async {
    if (!_initialized) return false;

    if (_entries.containsKey(imageId)) {
      _entries.remove(imageId);
      await _flush();
      return false;
    } else {
      _entries[imageId] = FavoriteEntry(
        imageId: imageId,
        name: meta['name'] as String? ?? '',
        uri: meta['uri'] as String? ?? '',
        sourceKey: meta['sourceKey'] as String? ?? 'pixiv:default',
        thumbnailUrl: meta['thumbnailUrl'] as String?,
        sourceInfo: meta,
        addedAt: DateTime.now(),
      );
      await _flush();
      return true;
    }
  }

  List<FavoriteEntry> listAll() {
    final entries = _entries.values.toList();
    entries.sort((a, b) => b.addedAt.compareTo(a.addedAt)); // 新しい順
    return entries;
  }

  int get count => _entries.length;

  Future<void> clear() async {
    _entries.clear();
    await _flush();
  }

  // --- 内部メソッド ---

  bool _isFlushing = false;
  bool _needsFlush = false;

  /// Atomic write with _isFlushing guard to prevent concurrent tmp file access
  /// when toggle() is called rapidly (e.g. double-tap).
  Future<void> _flush() async {
    if (_isFlushing) {
      _needsFlush = true;
      return;
    }
    _isFlushing = true;
    try {
      final data = {
        'entries': {
          for (final e in _entries.entries) e.key: e.value.toJson(),
        },
      };
      final tmpFile = File('${_file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(_file.path);
    } catch (e, st) {
      _log.warning('flush error', e, st);
      _needsFlush = true;
    } finally {
      _isFlushing = false;
      if (_needsFlush) {
        _needsFlush = false;
        _flush();
      }
    }
  }

  Future<void> _load() async {
    if (!_file.existsSync()) return;

    try {
      final content = await _file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final entries = data['entries'] as Map<String, dynamic>? ?? {};
      _entries.clear();
      for (final entry in entries.entries) {
        _entries[entry.key] = FavoriteEntry.fromJson(
          entry.key,
          entry.value as Map<String, dynamic>,
        );
      }
    } catch (e, st) {
      _log.warning('load error', e, st);
      _entries.clear();
    }
  }
}
