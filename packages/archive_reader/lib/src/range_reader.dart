import 'dart:typed_data';

/// Reads a byte range from a file.
/// Works with SMB readRange, HTTP Range requests, or local file I/O.
typedef RangeReader = Future<Uint8List> Function(int offset, int length);
