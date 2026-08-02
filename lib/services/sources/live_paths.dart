import 'dart:io';

/// Paths remembered only for as long as the file is still there.
///
/// Handing out a path is a promise about something outside this program, and
/// the caches those paths point into can be emptied from the settings screen
/// while the app is running. The stores themselves already allow for that —
/// `KeyedFileStore` drops an entry whose file has gone and says so — but a
/// path copied out of one and kept in a map is a second answer that nobody
/// self-heals.
///
/// That is what this is for. A remembered path is checked before it is handed
/// back, and forgotten if it no longer names a file, so the caller falls
/// through to whatever it does when it has never seen the thing before.
class LivePaths {
  final Map<String, String> _paths = {};

  /// The path remembered for [key], or null if there is none or the file it
  /// named has gone.
  String? operator [](String key) {
    final path = _paths[key];
    if (path == null) return null;
    if (File(path).existsSync()) return path;
    _paths.remove(key);
    return null;
  }

  void operator []=(String key, String path) => _paths[key] = path;

  /// Whether [key] was being remembered, whether or not its file survives.
  /// For a caller that has to let go of something else built from the path.
  bool wasRemembered(String key) => _paths.containsKey(key);

  void clear() => _paths.clear();
}
