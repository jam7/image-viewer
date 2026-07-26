import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/viewer_mark.dart';

/// How far into a work the reader got, as kept by the place rather than by
/// the screen. The rules that matter are which work it is about and whether
/// arriving on it should start anything.
void main() {
  test('a mark is about one work, and is dropped for any other', () {
    // The place may have moved on between the screen writing a mark and the
    // next one reading it: swiping replaces the session underneath.
    const mark = ViewerMark('smb:1700000000000:books\\movie.mp4', page: 3);

    expect(mark.forItem('smb:1700000000000:books\\movie.mp4'), mark);
    expect(mark.forItem('smb:1700000000000:books\\a.jpg'), isNull);
  });

  test('a position on its own does not mean "stopped"', () {
    // The two are separate so that a `?t=30` address can say where to start
    // without also saying not to. Only leaving a tab says that.
    const fromAddress = ViewerMark('a', at: Duration(seconds: 30));
    expect(fromAddress.paused, isFalse);

    const onLeaving = ViewerMark('a', at: Duration(seconds: 30), paused: true);
    expect(onLeaving.paused, isTrue);
  });

  test('a work that is not a video is simply at a page', () {
    const mark = ViewerMark('a', page: 7);
    expect(mark.page, 7);
    expect(mark.at, Duration.zero);
    expect(mark.total, Duration.zero);
  });

  test('two marks of the same reading are the same mark', () {
    const a = ViewerMark('a', page: 2, at: Duration(seconds: 5));
    const b = ViewerMark('a', page: 2, at: Duration(seconds: 5));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(const ViewerMark('a', page: 3, at: Duration(seconds: 5))));
  });
}
