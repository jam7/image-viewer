import 'package:flutter/foundation.dart';

import 'gallery_session.dart';

/// A browser-style tab (ADR 008): an identity plus a history of the places it
/// has visited.
///
/// The identity is [id], not the URI. The same place may be open in several
/// tabs, and a tab's place changes as it is navigated, so the URI belongs to a
/// history entry — a [GallerySession] — rather than to the tab.
///
/// Entries left behind in the history keep their loaded items and scroll
/// anchor, so going back restores the previous place without refetching.
class GalleryTab {
  static int _nextId = 0;

  final String id;
  final List<GallerySession> _history;
  int _index = 0;

  /// Bumped whenever the tab moves to a different entry, or the entry it is on
  /// learns its name. A tab bar showing this tab's label has to follow along,
  /// and it is not the one doing either — navigation happens inside the body,
  /// and the name can arrive with the first page.
  final ValueNotifier<int> revision = ValueNotifier(0);

  GalleryTab(GallerySession initial, {String? id})
      : id = id ?? 'tab${_nextId++}',
        _history = [initial] {
    _adopt(initial);
  }

  /// Sessions report what the chrome shows — a title that arrived late, a
  /// filter that narrowed — back to the tab, which is all the header watches.
  GallerySession _adopt(GallerySession session) {
    session.onEntryChanged = _bump;
    return session;
  }

  /// The place this tab is showing.
  GallerySession get current => _history[_index];

  List<GallerySession> get history => List.unmodifiable(_history);

  /// Position in [history]; 0 is where the tab started.
  int get index => _index;

  bool get canGoBack => _index > 0;
  bool get canGoForward => _index < _history.length - 1;

  /// Go to [session], dropping any entries ahead of the current one — the same
  /// thing a browser does when you follow a link after going back. The dropped
  /// sessions are disposed, since nothing can reach them again.
  void navigate(GallerySession session) {
    for (final dropped in _history.sublist(_index + 1)) {
      dropped.dispose();
    }
    _history.removeRange(_index + 1, _history.length);
    _history.add(_adopt(session));
    _index = _history.length - 1;
    _bump();
  }

  /// Swap the current entry for [session]. A reload of the same place — search
  /// options changed, favorites edited — is not a navigation and must not leave
  /// the stale entry in the history.
  void replaceCurrent(GallerySession session) {
    _history[_index].dispose();
    _history[_index] = _adopt(session);
    _bump();
  }

  /// Step back one entry. False if this is already the first one, which is the
  /// caller's cue to leave the tab instead.
  bool back() {
    if (!canGoBack) return false;
    _index--;
    _bump();
    return true;
  }

  bool forward() {
    if (!canGoForward) return false;
    _index++;
    _bump();
    return true;
  }

  void _bump() => revision.value++;

  Future<void> dispose() async {
    // Sessions first: disposing one drops its report-back, and a page still in
    // flight would otherwise bump a notifier that is already gone.
    for (final session in _history) {
      await session.dispose();
    }
    _history.clear();
    revision.dispose();
  }
}
