import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/services/sources/live_paths.dart';

/// The case this exists for: the reader empties the cache from the settings
/// screen while a PDF is open. The store that owned the file notices, because
/// it checks; a path copied out of it and kept in a map does not, and the
/// next open goes to a name with nothing behind it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('live_paths'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File aFile(String name) =>
      File('${dir.path}/$name')..writeAsStringSync('x');

  test('a path whose file is there comes back', () {
    final paths = LivePaths();
    final file = aFile('a.bin');

    paths['a'] = file.path;

    expect(paths['a'], file.path);
  });

  test('a path whose file has gone does not', () {
    final paths = LivePaths();
    final file = aFile('a.bin');
    paths['a'] = file.path;

    file.deleteSync();

    expect(paths['a'], isNull);
  });

  test('and is forgotten, so the caller starts over', () {
    // Not just "answers null this once": the entry goes, or a later restore
    // of the same file would be reported through a stale path that happens to
    // work again, which is worse than either.
    final paths = LivePaths();
    final file = aFile('a.bin');
    paths['a'] = file.path;
    file.deleteSync();

    expect(paths['a'], isNull);
    expect(paths.wasRemembered('a'), isFalse);
  });

  test('what was remembered can be asked about before it is checked', () {
    // The caller has its own thing built from the path — an open document —
    // and needs to know whether to let go of it.
    final paths = LivePaths();
    final file = aFile('a.bin');
    paths['a'] = file.path;
    file.deleteSync();

    expect(paths.wasRemembered('a'), isTrue, reason: 'before the check');
    expect(paths['a'], isNull);
    expect(paths.wasRemembered('a'), isFalse, reason: 'after it');
  });

  test('one key going does not take the others', () {
    final paths = LivePaths();
    final gone = aFile('gone.bin');
    final kept = aFile('kept.bin');
    paths['gone'] = gone.path;
    paths['kept'] = kept.path;

    gone.deleteSync();

    expect(paths['gone'], isNull);
    expect(paths['kept'], kept.path);
  });

  test('a key never seen is simply absent', () {
    expect(LivePaths()['nothing'], isNull);
  });
}
