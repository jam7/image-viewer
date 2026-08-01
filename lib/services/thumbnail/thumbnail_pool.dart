import 'package:flutter/foundation.dart';
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

  /// Who to tell when one particular thumbnail changes, by id.
  ///
  /// Per id rather than one list for the pool, because the point is to repaint
  /// one tile. A grid that repaints whole for every thumbnail that lands does
  /// so a hundred times over while a screenful arrives, and that is what a
  /// list scrolled through while it fills feels like.
  final Map<String, Set<VoidCallback>> _watchers = {};

  int get entryCount => _entries.length;
  int get bytes => _bytes;

  void watch(String id, VoidCallback onChanged) =>
      (_watchers[id] ??= {}).add(onChanged);

  void unwatch(String id, VoidCallback onChanged) {
    final forId = _watchers[id];
    if (forId == null) return;
    forId.remove(onChanged);
    if (forId.isEmpty) _watchers.remove(id);
  }

  /// A copy, because a watcher may well stop watching as it is told.
  void _tell(String id) {
    final forId = _watchers[id];
    if (forId == null) return;
    for (final watcher in forId.toList()) {
      watcher();
    }
  }

  /// What is held for [id], or null if nothing is — which means "ask for it",
  /// never "there is nothing to show".
  ThumbnailResult? get(String id) {
    final held = _entries.remove(id);
    if (held == null) return null;
    _entries[id] = held; // most recently used, so last to be dropped
    return held;
  }

  void put(String id, ThumbnailResult result) {
    // Not through [_forget]: telling a watcher about the moment between the
    // old answer and the new one would have it paint a spinner and ask again.
    final replaced = _entries.remove(id);
    if (replaced != null) _bytes -= _sizeOf(replaced);
    _entries[id] = result;
    _bytes += _sizeOf(result);
    _evict();
    // The same answer again is not news, and saying it were would spin: a
    // provisional failure is re-asked by painting, so a watcher told about it
    // would paint, ask, be told again, and paint again.
    if (!_sameAnswer(replaced, result)) _tell(id);
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
    final held = _entries.keys.toList();
    _entries.clear();
    _bytes = 0;
    held.forEach(_tell);
  }

  void _forget(String id) {
    final gone = _entries.remove(id);
    if (gone == null) return;
    _bytes -= _sizeOf(gone);
    // Whoever is watching is showing what has just gone, and asks again by
    // being painted. Includes being pushed out by [_evict], which is how a
    // tile scrolled far away and back finds itself asking a second time.
    _tell(id);
  }

  void _evict() {
    while (_entries.isNotEmpty &&
        (_bytes > maxBytes || _entries.length > maxEntries)) {
      _forget(_entries.keys.first);
    }
  }

  static bool _sameAnswer(ThumbnailResult? before, ThumbnailResult now) =>
      before is ThumbnailFailed &&
      now is ThumbnailFailed &&
      before.reason == now.reason;

  static int _sizeOf(ThumbnailResult result) =>
      result is ThumbnailData ? result.data.length : 0;

  static String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
}
