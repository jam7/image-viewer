import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/screens/viewer/rendered_pages.dart';

/// Every one of these is about the same thing: an image that leaves this
/// collection is disposed. A leak here is invisible — the app keeps working
/// and then runs out of memory somewhere else entirely — so the discipline is
/// kept in one class and pinned by counting, rather than trusted to the four
/// places that used to drop map entries.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> anImage() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = const Color(0xFF000000));
    return recorder.endRecording().toImage(4, 4);
  }

  testWidgets('holds what it is given', (tester) async {
    await tester.runAsync(() async {
      final pages = RenderedPages();
      final image = await anImage();

      pages.put('a', image);

      expect(pages['a'], same(image));
      expect(pages.contains('a'), isTrue);
      expect(pages.length, 1);
    });
  });

  testWidgets('a second render of the same page disposes the first',
      (tester) async {
    await tester.runAsync(() async {
      final pages = RenderedPages();
      final first = await anImage();
      final second = await anImage();

      pages.put('a', first);
      pages.put('a', second);

      expect(first.debugDisposed, isTrue);
      expect(second.debugDisposed, isFalse);
      expect(pages['a'], same(second));
    });
  });

  testWidgets('putting the same image back is not a disposal', (tester) async {
    await tester.runAsync(() async {
      final pages = RenderedPages();
      final image = await anImage();

      pages.put('a', image);
      pages.put('a', image);

      expect(image.debugDisposed, isFalse);
      expect(pages['a'], same(image));
    });
  });

  testWidgets('what the reader moved away from is disposed', (tester) async {
    await tester.runAsync(() async {
      final pages = RenderedPages();
      final near = await anImage();
      final far = await anImage();
      pages.put('near', near);
      pages.put('far', far);

      pages.keepOnly({'near'});

      expect(far.debugDisposed, isTrue);
      expect(near.debugDisposed, isFalse);
      expect(pages.length, 1);
    });
  });

  testWidgets('leaving the viewer disposes all of them', (tester) async {
    await tester.runAsync(() async {
      final pages = RenderedPages();
      final images = [await anImage(), await anImage(), await anImage()];
      for (var i = 0; i < images.length; i++) {
        pages.put('p$i', images[i]);
      }

      pages.clear();

      expect(images.every((i) => i.debugDisposed), isTrue);
      expect(pages.length, 0);
    });
  });

  testWidgets('keeping everything disposes nothing', (tester) async {
    await tester.runAsync(() async {
      final pages = RenderedPages();
      final image = await anImage();
      pages.put('a', image);

      pages.keepOnly({'a', 'b'});

      expect(image.debugDisposed, isFalse);
      expect(pages.length, 1);
    });
  });
}
