import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../widgets/thumbnail_result.dart';
import '../cache/cache_manager.dart';
import '../sources/image_source_provider.dart';
import 'thumbnail_pool.dart';

final _log = Logger('ThumbnailScheduler');

/// Answers requests for thumbnails, nearest to the viewport first (ADR 011).
///
/// Nothing here decides *what* to ask for: a tile being painted asks for its
/// own, and a view about to scroll asks ahead for the band around it. That is
/// the whole reason this exists — the thing it replaced worked from a
/// watermark into the list, so it fetched what had been scrolled past whether
/// or not anyone was looking, and had to keep a ledger of what it had handed
/// out. What is asked for here is what is wanted now, and what stops being
/// wanted is simply dropped.
///
/// One per place. Only the active tab has a view, so only one of these has
/// anything to do at a time, and its limits are the app's limits. (ADR 011
/// describes one for the app; per-place turns out to be the same thing while
/// that stays true, and needs nothing threaded through to reach it.)
class ThumbnailScheduler {
  final CacheManager cache;
  final ThumbnailPool pool;
  final ImageSourceProvider source;

  /// Where a result goes when it lands. The pool is written first, so this is
  /// for repainting, not for keeping.
  final void Function(String id, ThumbnailResult result) onResult;

  /// How many thumbnails to work on at once, and how many of those may be
  /// waiting on the source rather than on the disk. Reading is cheap and
  /// parallel; fetching is neither, and the share is shared.
  final int lanes;
  final int fetchLanes;

  ThumbnailScheduler({
    required this.cache,
    required this.pool,
    required this.source,
    required this.onResult,
    this.lanes = 8,
    this.fetchLanes = 5,
  });

  /// Wanted but not started, by item id. Insertion order is meaningless here;
  /// [_next] picks by distance.
  final Map<String, _Want> _wanted = {};
  final Set<String> _running = {};

  int _busy = 0;
  int _videoBusy = 0;
  late final _fetchGate = _Gate(fetchLanes);

  /// Bumped by [cancel]; work from an older round drops its result.
  int _round = 0;

  /// Set while a video is playing, when the source's decoder is needed for
  /// something more important than a still.
  bool _stillsPaused = false;

  int _asked = 0;
  int _fromPool = 0;
  int _fromCache = 0;
  int _fetched = 0;
  Stopwatch? _wave;

  /// Ask for [item]'s thumbnail, [distance] rows from what is on screen (0 is
  /// on screen). Asking twice is free; the shorter distance wins.
  ///
  /// Answers that are already held are not re-asked, and that includes
  /// failures: "there is no thumbnail for this" is an answer.
  void want(ImageSource item, {int distance = 0}) {
    // A folder is not a picture and never will be. The tile draws one and does
    // not ask, but a band asks for whatever is in it.
    if (item.metadata?['isDirectory'] == true) return;
    if (pool.get(item.id) != null) {
      _fromPool++;
      return;
    }
    if (_running.contains(item.id)) return;
    final waiting = _wanted[item.id];
    if (waiting != null) {
      if (distance < waiting.distance) waiting.distance = distance;
      return;
    }
    _asked++;
    _wave ??= Stopwatch()..start();
    _wanted[item.id] = _Want(item, distance);
    _pump();
  }

  /// Drop what is no longer near enough to matter. Painting asks again, so
  /// dropping costs nothing but the asking.
  void keepOnly(bool Function(String id) stillWanted) {
    _wanted.removeWhere((id, _) => !stillWanted(id));
  }

  /// The view went away. Forget what was wanted and disown what is running —
  /// a fetch already under way is left to finish into the cache, since it has
  /// paid for itself either way.
  void cancel() {
    _round++;
    _wanted.clear();
    _stillsPaused = false;
    source.cancelThumbnailWork();
  }

  /// Stop making stills while the source is needed for playing something.
  void pauseStills() {
    _stillsPaused = true;
    source.cancelThumbnailWork();
  }

  void resumeStills() {
    _stillsPaused = false;
    _pump();
  }

  Future<void> dispose() async => cancel();

  /// Start whatever there is room to start.
  void _pump() {
    while (_busy < lanes) {
      final next = _next();
      if (next == null) break;
      _wanted.remove(next.item.id);
      _running.add(next.item.id);
      _busy++;
      if (_isVideo(next.item)) _videoBusy++;
      unawaited(_serve(next, _round));
    }
  }

  /// The nearest thing worth starting.
  ///
  /// A still from a video costs a decoder and a connection of its own, so one
  /// at a time and only once the pictures are done: a folder of films would
  /// otherwise show nothing for as long as it takes to open each of them.
  _Want? _next() {
    _Want? best;
    for (final want in _wanted.values) {
      if (_isVideo(want.item)) continue;
      if (best == null || want.distance < best.distance) best = want;
    }
    if (best != null) return best;
    if (_stillsPaused || _videoBusy > 0 || _busy > 0) return null;
    for (final want in _wanted.values) {
      if (best == null || want.distance < best.distance) best = want;
    }
    return best;
  }

  Future<void> _serve(_Want want, int round) async {
    final key = 'thumb:${want.item.id}';
    try {
      final cached = await cache.get(key);
      if (cached != null) {
        _fromCache++;
        _finish(want, round, ThumbnailData(Uint8List.fromList(cached.data)));
        return;
      }
      // Waiting for a fetching slot inside the lane, so that reads of the
      // disk do not queue behind the share. Kept out of L1: ten entries shared
      // with full-size images is not a thumbnail cache, and the pool is.
      final data = await _fetchGate.run(() => source.fetchThumbnail(want.item));
      _fetched++;
      await cache.l2.put(key, data);
      _finish(want, round, ThumbnailData(data));
    } on ThumbnailNotSupportedException {
      _log.info('no thumbnail for ${want.item.name}');
      _finish(want, round, ThumbnailFailed(ThumbnailFailReason.notSupported));
    } catch (e, st) {
      _log.warning('thumbnail error (${want.item.name})', e, st);
      _finish(want, round, ThumbnailFailed(ThumbnailFailReason.timeout));
    }
  }

  /// Keep the answer and say so — even for a round that has been cancelled,
  /// since the work is done and the answer is as good now as it was asked for.
  void _finish(_Want want, int round, ThumbnailResult result) {
    pool.put(want.item.id, result);
    _done(want);
    if (round == _round) onResult(want.item.id, result);
  }

  void _done(_Want want) {
    _running.remove(want.item.id);
    _busy--;
    if (_isVideo(want.item)) _videoBusy--;
    if (_wanted.isEmpty && _busy == 0) _reportWave();
    _pump();
  }

  /// One line per run of asking, so that a list which feels slow can be told
  /// apart from one that is being fetched again (the question that started
  /// ADR 011, and the log that answered it).
  void _reportWave() {
    final wave = _wave;
    if (wave == null || _asked == 0) return;
    _log.info(
      'wave: $_asked wanted = $_fromPool held + $_fromCache cached + '
      '$_fetched fetched, ${wave.elapsedMilliseconds}ms',
    );
    _wave = null;
    _asked = _fromPool = _fromCache = _fetched = 0;
  }

  static bool _isVideo(ImageSource item) => item.metadata?['isVideo'] == true;
}

/// Lets at most [limit] tasks run at once; the rest wait their turn.
class _Gate {
  _Gate(this.limit);

  final int limit;
  int _busy = 0;
  final List<Completer<void>> _waiting = [];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_busy >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _busy++;
    try {
      return await task();
    } finally {
      _busy--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

class _Want {
  final ImageSource item;
  int distance;
  _Want(this.item, this.distance);
}
