/// Natural sort comparison function.
/// Numeric parts are compared as numbers so "1", "2", "10" sort correctly.
/// File extensions are compared separately so that base name ordering
/// takes priority (e.g. 03.jpg < 03-02.jpg < 03-03.jpg).
///
/// Supported patterns:
/// - 1.jpg, 2.jpg, 10.jpg
/// - 004-1.jpg, 004-2.jpg, 004-10.jpg
/// - file(1).jpg, file(2).jpg, file(10).jpg
/// - chapter1_page3.jpg, chapter1_page12.jpg
/// - 03.jpg, 03-02.jpg, 03-03.jpg
int naturalCompare(String a, String b) {
  final (baseA, extA) = _splitExtension(a.toLowerCase());
  final (baseB, extB) = _splitExtension(b.toLowerCase());

  final cmp = _compareSegments(
    _splitSegments(baseA),
    _splitSegments(baseB),
  );
  if (cmp != 0) return cmp;

  // Base names equal — compare extensions
  return extA.compareTo(extB);
}

int _compareSegments(List<Object> segA, List<Object> segB) {
  final len = segA.length < segB.length ? segA.length : segB.length;
  for (var i = 0; i < len; i++) {
    final sa = segA[i];
    final sb = segB[i];

    // Both numeric
    if (sa is int && sb is int) {
      if (sa != sb) return sa.compareTo(sb);
      continue;
    }

    // One is numeric (numbers sort before text)
    if (sa is int) return -1;
    if (sb is int) return 1;

    // Both strings
    final cmp = (sa as String).compareTo(sb as String);
    if (cmp != 0) return cmp;
  }

  return segA.length.compareTo(segB.length);
}

/// Split "filename.ext" into ("filename", "ext").
/// If no extension, returns (original, "").
(String, String) _splitExtension(String s) {
  final dot = s.lastIndexOf('.');
  if (dot <= 0) return (s, '');
  return (s.substring(0, dot), s.substring(dot + 1));
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
