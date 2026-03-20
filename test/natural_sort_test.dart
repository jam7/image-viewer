import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/utils/natural_sort.dart';

void main() {
  test('basic numeric sort', () {
    final list = ['10.jpg', '2.jpg', '1.jpg'];
    list.sort(naturalCompare);
    expect(list, ['1.jpg', '2.jpg', '10.jpg']);
  });

  test('sub-numbers with dash', () {
    final list = ['004-10.jpg', '004-1.jpg', '004-2.jpg'];
    list.sort(naturalCompare);
    expect(list, ['004-1.jpg', '004-2.jpg', '004-10.jpg']);
  });

  test('base number before sub-numbered', () {
    final list = ['03-03.jpg', '03.jpg', '03-02.jpg'];
    list.sort(naturalCompare);
    expect(list, ['03.jpg', '03-02.jpg', '03-03.jpg']);
  });

  test('mixed base and sub-numbered across groups', () {
    final list = ['04.jpg', '03-03.jpg', '03.jpg', '03-02.jpg', '04-01.jpg'];
    list.sort(naturalCompare);
    expect(list, ['03.jpg', '03-02.jpg', '03-03.jpg', '04.jpg', '04-01.jpg']);
  });

  test('chapter/page pattern', () {
    final list = ['chapter1_page12.jpg', 'chapter1_page3.jpg'];
    list.sort(naturalCompare);
    expect(list, ['chapter1_page3.jpg', 'chapter1_page12.jpg']);
  });

  test('parentheses pattern', () {
    final list = ['file(10).jpg', 'file(1).jpg', 'file(2).jpg'];
    list.sort(naturalCompare);
    expect(list, ['file(1).jpg', 'file(2).jpg', 'file(10).jpg']);
  });

  test('no extension', () {
    final list = ['10', '2', '1'];
    list.sort(naturalCompare);
    expect(list, ['1', '2', '10']);
  });

  test('different extensions same base', () {
    final list = ['file.png', 'file.jpg'];
    list.sort(naturalCompare);
    expect(list, ['file.jpg', 'file.png']);
  });
}
