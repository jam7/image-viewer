import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/services/thumbnail/thumbnail_pool.dart';
import 'package:image_viewer/widgets/thumbnail_result.dart';

/// The pool is what lets thumbnails survive leaving a place (ADR 011), so what
/// matters is what it keeps, what it drops first, and that dropping something
/// reads as "ask again" rather than "there is nothing".
void main() {
  ThumbnailData picture(int bytes) =>
      ThumbnailData(Uint8List.fromList(List.filled(bytes, 7)));

  test('what was put in comes back', () {
    final pool = ThumbnailPool();
    pool.put('a', picture(10));

    expect(pool.get('a'), isA<ThumbnailData>());
    expect(pool.get('b'), isNull);
  });

  test('a failure is kept too: it is an answer, not a gap', () {
    // Forgetting it means asking the share for a thumbnail it has already said
    // it cannot make, every time the tile is painted.
    final pool = ThumbnailPool();
    pool.put('a', ThumbnailFailed(ThumbnailFailReason.notSupported));

    expect(pool.get('a'), isA<ThumbnailFailed>());
    expect(pool.bytes, 0, reason: 'a failure costs no memory');
  });

  test('the least recently used goes when there is no room', () {
    final pool = ThumbnailPool(maxBytes: 25);
    pool.put('a', picture(10));
    pool.put('b', picture(10));
    pool.get('a'); // now 'b' is the older of the two
    pool.put('c', picture(10));

    expect(pool.get('b'), isNull);
    expect(pool.get('a'), isNotNull);
    expect(pool.get('c'), isNotNull);
    expect(pool.bytes, 20);
  });

  test('failures cannot fill it either, though they weigh nothing', () {
    final pool = ThumbnailPool(maxEntries: 2);
    pool.put('a', ThumbnailFailed(ThumbnailFailReason.timeout));
    pool.put('b', ThumbnailFailed(ThumbnailFailReason.timeout));
    pool.put('c', ThumbnailFailed(ThumbnailFailReason.timeout));

    expect(pool.entryCount, 2);
    expect(pool.get('a'), isNull);
  });

  test('putting over an entry replaces it rather than counting twice', () {
    final pool = ThumbnailPool();
    pool.put('a', picture(10));
    pool.put('a', picture(4));

    expect(pool.entryCount, 1);
    expect(pool.bytes, 4);
  });

  test('what is dropped is asked for again, which is how a retry is spelled', () {
    final pool = ThumbnailPool();
    pool.put('a', ThumbnailFailed(ThumbnailFailReason.notSupported));
    pool.put('b', picture(10));

    pool.removeWhere((_, result) => result is ThumbnailFailed);

    expect(pool.get('a'), isNull);
    expect(pool.get('b'), isNotNull);
    expect(pool.bytes, 10);
  });
}
