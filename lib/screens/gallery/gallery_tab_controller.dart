import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'gallery_tab.dart';

final _log = Logger('GalleryTabs');

/// The set of open tabs and which one is showing (ADR 008).
///
/// Deliberately does not merge tabs pointing at the same place: opening the
/// same folder or search twice is allowed, which is why a tab's identity is its
/// own id rather than its URI.
///
/// Lives above the gallery route so tabs outlive any one screen.
class GalleryTabController extends ChangeNotifier {
  final List<GalleryTab> _tabs = [];
  int _activeIndex = 0;

  List<GalleryTab> get tabs => List.unmodifiable(_tabs);
  bool get isEmpty => _tabs.isEmpty;
  int get activeIndex => _activeIndex;

  /// The tab on screen, or null when none are open.
  GalleryTab? get active => _tabs.isEmpty ? null : _tabs[_activeIndex];

  /// Add [tab] at the end. [activate] switches to it; opening in the
  /// background is what "open in a new tab" means when you long-press
  /// something, so several places can be lined up without losing your place.
  /// The chip appearing in the strip is the feedback either way.
  void open(GalleryTab tab, {bool activate = true}) {
    _tabs.add(tab);
    if (activate) _activeIndex = _tabs.length - 1;
    notifyListeners();
  }

  void select(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeIndex) return;
    _activeIndex = index;
    final tab = _tabs[index];
    _log.info('select: tab=${tab.id} '
        'index=${tab.index}/${tab.history.length}');
    notifyListeners();
  }

  /// Close the tab at [index]. The neighbour on the left takes over, matching
  /// what a browser does, so closing the last tab in a row keeps you near where
  /// you were rather than jumping to the far end.
  void close(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _tabs.removeAt(index).dispose();
    if (_tabs.isEmpty) {
      _activeIndex = 0;
    } else if (index < _activeIndex || _activeIndex >= _tabs.length) {
      _activeIndex = (_activeIndex - 1).clamp(0, _tabs.length - 1);
    }
    notifyListeners();
  }

  void closeAll() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    _tabs.clear();
    _activeIndex = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}
