/// 自然順ソート比較関数。
/// 文字列中の数字部分を数値として比較するため、
/// "1", "2", "10" が正しく並ぶ。
///
/// 対応パターン例:
/// - 1.jpg, 2.jpg, 10.jpg
/// - 004-1.jpg, 004-2.jpg, 004-10.jpg
/// - file(1).jpg, file(2).jpg, file(10).jpg
/// - chapter1_page3.jpg, chapter1_page12.jpg
int naturalCompare(String a, String b) {
  final segA = _splitSegments(a.toLowerCase());
  final segB = _splitSegments(b.toLowerCase());

  final len = segA.length < segB.length ? segA.length : segB.length;
  for (var i = 0; i < len; i++) {
    final sa = segA[i];
    final sb = segB[i];

    // 両方数値
    if (sa is int && sb is int) {
      if (sa != sb) return sa.compareTo(sb);
      continue;
    }

    // 片方だけ数値（数値を先にする）
    if (sa is int) return -1;
    if (sb is int) return 1;

    // 両方文字列
    final cmp = (sa as String).compareTo(sb as String);
    if (cmp != 0) return cmp;
  }

  return segA.length.compareTo(segB.length);
}

/// 文字列をテキストと数字のセグメントに分割。
/// "file10abc2" → ["file", 10, "abc", 2]
List<Object> _splitSegments(String s) {
  final segments = <Object>[];
  final buf = StringBuffer();
  bool? inDigit;

  for (final ch in s.codeUnits) {
    final isDigit = ch >= 0x30 && ch <= 0x39; // '0'-'9'
    if (inDigit != null && isDigit != inDigit) {
      final text = buf.toString();
      segments.add(inDigit ? int.parse(text) : text);
      buf.clear();
    }
    buf.writeCharCode(ch);
    inDigit = isDigit;
  }

  if (buf.isNotEmpty) {
    final text = buf.toString();
    segments.add(inDigit == true ? int.parse(text) : text);
  }

  return segments;
}
