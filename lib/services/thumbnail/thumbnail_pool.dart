import 'package:logging/logging.dart';

import '../../widgets/thumbnail_result.dart';

final _log = Logger('ThumbnailPool');

/// Thumbnails ready to paint, for the whole app, up to a size (ADR 011).
///
/// One pool rather than one per place, because a place is left and returned to
/// constantly — and a per-place store has to be emptied on the way out or the
/// app grows by everything ever scrolled past. That emptying is what made
/// coming back to a tab cost ten seconds of disk: everything had been thrown
/// away, so everything had to be read again.
///
/// A bound is what makes keeping them safe. The oldest go first, by bytes
/// rather than by count, since that is what actually runs out; [maxEntries] is
/// a second bound for the failures, which cost nothing to hold and would
/// otherwise never be pushed out at all.
///
/// A failure is kept as deliberately as a picture. "There is no thumbnail for
/// this" is an answer, and forgetting it means asking the share again every
/// time the tile is painted.
class ThumbnailPool {
  /// Roughly 1000 thumbnails at the size the app makes them (long edge 600px,
  /// under 400KB, in practice tens of KB).
  static const defaultMaxBytes = 32 * 1024 * 1024;

  final int maxBytes;
  final int maxEntries;

  /// Insertion-ordered, and re-inserted on every read: the first key is
  /// therefore the least recently used one.
  final Map<String, ThumbnailResult> _entries = {};
  int _bytes = 0;
  int _putsSinceLog = 0;

  ThumbnailPool({this.maxBytes = defaultMaxBytes, this.maxEntries = 2048});

  int get entryCount => _entries.length;
  int get bytes => _bytes;

  /// What is held for [id], or null if nothing is — which means "ask for it",
  /// never "there is nothing to show".
  ThumbnailResult? get(String id) {
    final held = _entries.remove(id);
    if (held == null) return null;
    _entries[id] = held; // most recently used, so last to be dropped
    return held;
  }

  void put(String id, ThumbnailResult result) {
    _forget(id);
    _entries[id] = result;
    _bytes += _sizeOf(result);
    _evict();
    if (++_putsSinceLog >= 256) {
      _putsSinceLog = 0;
      _log.info('pool: ${_entries.length} entries, ${_mb(_bytes)}MB');
    }
  }

  /// Drop what [test] selects, so it will be asked for again. How a retry is
  /// spelled: there is no separate "retry" state, only the absence of an
  /// answer.
  void removeWhere(bool Function(String id, ThumbnailResult result) test) {
    final doomed = [
      for (final entry in _entries.entries)
        if (test(entry.key, entry.value)) entry.key,
    ];
    doomed.forEach(_forget);
  }

  /// Let go of everything. What "clear the cache" has to mean here as well:
  /// thumbnails held in memory would otherwise outlive the files they came
  /// from, and the grid would go on showing what was just deleted.
  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _forget(String id) {
    final gone = _entries.remove(id);
    if (gone != null) _bytes -= _sizeOf(gone);
  }

  void _evict() {
    while (_entries.isNotEmpty &&
        (_bytes > maxBytes || _entries.length > maxEntries)) {
      _forget(_entries.keys.first);
    }
  }

  static int _sizeOf(ThumbnailResult result) =>
      result is ThumbnailData ? result.data.length : 0;

  static String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
}
