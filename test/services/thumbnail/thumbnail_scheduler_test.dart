import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/services/cache/cache_manager.dart';
import 'package:image_viewer/services/cache/disk_cache.dart';
import 'package:image_viewer/services/cache/download_store.dart';
import 'package:image_viewer/services/cache/memory_cache.dart';
import 'package:image_viewer/services/sources/image_source_provider.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/thumbnail/thumbnail_pool.dart';
import 'package:image_viewer/services/thumbnail/thumbnail_scheduler.dart';
import 'package:image_viewer/widgets/thumbnail_result.dart';

/// What answering a request for a thumbnail costs, and in what order (ADR
/// 011). The promises a reader sees are in thumbnail_supply_test; these are
/// the ones only the scheduler can keep.
void main() {
  late Directory tempDir;
  late CacheManager cache;
  late ThumbnailPool pool;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('thumb_sched_test');
    final l2 = DiskCache();
    await l2.init(baseDir: Directory('${tempDir.path}/l2')..createSync());
    final l3 = DownloadStore();
    await l3.init(baseDir: Directory('${tempDir.path}/l3')..createSync());
    cache = CacheManager(l1: MemoryCache(maxEntries: 200), l2: l2, l3: l3);
    pool = cache.thumbnails;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ImageSource picture(String id) => ImageSource(
    id: id,
    name: '$id.jpg',
    uri: 'smb://server/share/$id.jpg',
    type: ImageSourceType.smb,
    sourceKey: 'smb:test',
    metadata: const {'isDirectory': false},
  );

  ImageSource film(String id) => ImageSource(
    id: id,
    name: '$id.mp4',
    uri: 'smb://server/share/$id.mp4',
    type: ImageSourceType.smb,
    sourceKey: 'smb:test',
    metadata: const {'isDirectory': false, 'isVideo': true},
  );

  ImageSource folder(String id) => ImageSource(
    id: id,
    name: id,
    uri: 'smb://server/share/$id',
    type: ImageSourceType.smb,
    sourceKey: 'smb:test',
    metadata: const {'isDirectory': true},
  );

  ({ThumbnailScheduler scheduler, List<String> answered}) schedulerFor(
    _FakeShare share, {
    int lanes = 8,
    int fetchLanes = 5,
  }) {
    final answered = <String>[];
    return (
      scheduler: ThumbnailScheduler(
        cache: cache,
        pool: pool,
        source: share,
        onResult: (id, _) => answered.add(id),
        lanes: lanes,
        fetchLanes: fetchLanes,
      ),
      answered: answered,
    );
  }

  /// Let the queue drain. Real time, because storing a thumbnail writes a file.
  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 80));

  test('what is asked for is fetched, kept, and reported', () async {
    final share = _FakeShare();
    final (:scheduler, :answered) = schedulerFor(share);

    scheduler.want(picture('a'));
    await drain();

    expect(share.fetched, ['a']);
    expect(pool.get('a'), isA<ThumbnailData>());
    expect(answered, ['a']);
    // And it is on the disk for the next run of the app.
    expect(await cache.get('thumb:a'), isNotNull);
  });

  test('what the cache already has is not fetched', () async {
    await cache.l2.put('thumb:a', Uint8List.fromList([1, 2, 3]));
    final share = _FakeShare();
    final (:scheduler, :answered) = schedulerFor(share);

    scheduler.want(picture('a'));
    await drain();

    expect(share.fetched, isEmpty);
    expect(answered, ['a']);
  });

  test('asking twice for the same thing does the work once', () async {
    final share = _FakeShare();
    final (:scheduler, :answered) = schedulerFor(share);

    scheduler.want(picture('a'));
    scheduler.want(picture('a'), distance: 2);
    await drain();
    scheduler.want(picture('a')); // and again now it is answered

    await drain();
    expect(share.fetched, ['a']);
  });

  test('a folder is never asked about', () async {
    final share = _FakeShare();
    final scheduler = schedulerFor(share).scheduler;

    scheduler.want(folder('books'));
    await drain();

    expect(share.fetched, isEmpty);
  });

  test('the nearest to the viewport goes first', () async {
    // One lane, so the order they come out in is the order they were chosen.
    // A whole band is asked for in one go and starts once, after it: the far
    // one asked for first does not get a head start on the visible one.
    final share = _FakeShare(hold: true);
    final scheduler = schedulerFor(share, lanes: 1).scheduler;

    scheduler.want(picture('far'), distance: 5);
    scheduler.want(picture('near'), distance: 0);
    scheduler.want(picture('middle'), distance: 2);
    for (var i = 0; i < 4; i++) {
      share.releaseOne();
      await drain();
    }

    expect(share.fetched, ['near', 'middle', 'far']);
  });

  test('films wait for the pictures, and for each other', () async {
    final share = _FakeShare(hold: true);
    final scheduler = schedulerFor(share, lanes: 8).scheduler;

    for (var i = 0; i < 3; i++) {
      scheduler.want(picture('p$i'));
    }
    scheduler.want(film('v0'));
    scheduler.want(film('v1'));
    await drain();

    expect(share.inFlight.toSet(), {'p0', 'p1', 'p2'},
        reason: 'no film starts while there are pictures to make');

    share.releaseAll();
    await drain();
    expect(share.mostFilmsAtOnce, 1);
    expect(share.fetched.sublist(3), ['v0', 'v1']);
  });

  test('no more than the fetch lanes are at the share at once', () async {
    final share = _FakeShare(hold: true);
    final scheduler = schedulerFor(share, lanes: 8, fetchLanes: 2).scheduler;

    for (var i = 0; i < 6; i++) {
      scheduler.want(picture('p$i'));
    }
    await drain();

    expect(share.inFlight, hasLength(2));
    share.releaseAll();
    await drain();
    expect(share.fetched, hasLength(6));
  });

  test('a view going away stops what has not started', () async {
    final share = _FakeShare(hold: true);
    final (:scheduler, :answered) = schedulerFor(share, lanes: 1);

    scheduler.want(picture('a'));
    scheduler.want(picture('b'));
    await drain();
    scheduler.cancel();
    share.releaseAll();
    await drain();

    expect(share.fetched, ['a'], reason: 'b never started');
    // What did start is still kept — it was paid for — but nobody is told,
    // because whoever asked is no longer there.
    expect(pool.get('a'), isA<ThumbnailData>());
    expect(answered, isEmpty);
  });

  test('a file with no thumbnail is answered, not left hanging', () async {
    final share = _FakeShare(unsupported: {'a'});
    final (:scheduler, :answered) = schedulerFor(share);

    scheduler.want(picture('a'));
    await drain();

    expect(pool.get('a'), isA<ThumbnailFailed>());
    expect(answered, ['a']);
  });

  test('what stops being wanted is dropped before it starts', () async {
    final share = _FakeShare(hold: true);
    final scheduler = schedulerFor(share, lanes: 1).scheduler;

    scheduler.want(picture('a'));
    scheduler.want(picture('gone'));
    scheduler.keepOnly((id) => id != 'gone');
    share.releaseAll();
    await drain();

    expect(share.fetched, ['a']);
  });
}

/// A share that can be made to hold its answers, so that ordering and how many
/// are in flight can be looked at.
class _FakeShare extends SmbSource {
  final bool hold;
  final Set<String> unsupported;

  final List<String> fetched = [];
  final List<String> inFlight = [];
  int mostFilmsAtOnce = 0;
  int _filmsInFlight = 0;
  final List<void Function()> _held = [];
  late bool _holding = hold;

  _FakeShare({this.hold = false, this.unsupported = const {}})
    : super(
        config: const ServerConfig(
          id: 'test',
          name: 'test',
          type: ImageSourceType.smb,
          host: 'localhost',
        ),
        password: '',
      );

  void releaseOne() {
    if (_held.isNotEmpty) _held.removeAt(0)();
  }

  /// Release everything and stop holding: what starts afterwards runs free,
  /// so a test can watch the queue drain rather than deadlock on the next one.
  void releaseAll() {
    _holding = false;
    while (_held.isNotEmpty) {
      _held.removeAt(0)();
    }
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    fetched.add(source.id);
    inFlight.add(source.id);
    final isFilm = source.metadata?['isVideo'] == true;
    if (isFilm && ++_filmsInFlight > mostFilmsAtOnce) {
      mostFilmsAtOnce = _filmsInFlight;
    }
    try {
      if (_holding) {
        final turn = Completer<void>();
        _held.add(() => turn.complete());
        await turn.future;
      }
      if (unsupported.contains(source.id)) {
        throw ThumbnailNotSupportedException(source.name);
      }
      return Uint8List.fromList([1, 2, 3]);
    } finally {
      inFlight.remove(source.id);
      if (isFilm) _filmsInFlight--;
    }
  }
}
