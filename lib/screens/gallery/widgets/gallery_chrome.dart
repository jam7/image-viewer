import 'package:flutter/widgets.dart';

/// Whether the two header rows are showing (ADR 009), shared down the tree.
///
/// The rows belong to the host and the scrolling happens in the body, several
/// widgets below it, so the two need a way to reach each other. Handing it
/// down through every body and view would put a parameter about the header on
/// widgets that draw grids; this way only the two ends of the wire know.
class GalleryChrome extends InheritedWidget {
  final ValueNotifier<bool> visible;

  const GalleryChrome({
    super.key,
    required this.visible,
    required super.child,
  });

  /// Null where nothing provides it — a view pumped on its own in a test, or
  /// any future screen outside the tab host. Callers just skip hiding then.
  static ValueNotifier<bool>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<GalleryChrome>()
      ?.visible;

  @override
  bool updateShouldNotify(GalleryChrome old) => old.visible != visible;
}

/// Turns scrolling into a verdict on the header: reading forward folds it
/// away, and any move back brings it straight out again.
///
/// Kept apart from the widget so the awkward part — what counts as a move,
/// and what happens at the very top — can be tried without a viewport.
class ChromeScrollRule {
  /// How far the list must run forward before the header goes. Below this,
  /// the wobble of a finger resting on the screen would flap it.
  static const _travelToHide = 32.0;

  /// Where the list was when it last changed its mind about direction.
  double _mark = 0;
  bool _visible = true;
  bool _started = false;

  /// Where the list is before anyone has touched it.
  ///
  /// A revisited place opens where it was left, which may be a long way down;
  /// that is not the reader scrolling forward, and measuring from the top
  /// would fold the header away on the first flick. Called when a list appears
  /// rather than waiting for the first movement, so that movement counts.
  void start(double offset) {
    _started = true;
    _mark = offset;
    _visible = true;
  }

  /// The header's state after scrolling to [offset], or null if it does not
  /// change. [atTop] keeps it out at rest: a list that has not been moved
  /// should never be missing the way to leave it.
  bool? update(double offset, {required bool atTop}) {
    if (!_started) {
      start(offset);
      return null;
    }
    if (atTop) {
      _mark = offset;
      return _turn(true);
    }
    if (offset < _mark) {
      // Any amount backwards is deliberate, so answer at once. Waiting for a
      // threshold here is what makes a header feel reluctant.
      _mark = offset;
      return _turn(true);
    }
    if (offset - _mark < _travelToHide) return null;
    _mark = offset;
    return _turn(false);
  }

  bool? _turn(bool to) {
    if (_visible == to) return null;
    _visible = to;
    return to;
  }
}

/// Folds its child up out of the way when the chrome is hidden.
///
/// Slides rather than shrinks: the rows keep their own height and are clipped
/// from the top, so nothing inside them is ever squashed on the way out.
class GalleryChromeSlot extends StatefulWidget {
  final ValueNotifier<bool> visible;
  final Widget child;

  const GalleryChromeSlot({
    super.key,
    required this.visible,
    required this.child,
  });

  @override
  State<GalleryChromeSlot> createState() => _GalleryChromeSlotState();
}

class _GalleryChromeSlotState extends State<GalleryChromeSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    widget.visible.addListener(_follow);
  }

  @override
  void didUpdateWidget(GalleryChromeSlot old) {
    super.didUpdateWidget(old);
    if (old.visible == widget.visible) return;
    old.visible.removeListener(_follow);
    widget.visible.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.visible.removeListener(_follow);
    _reveal.dispose();
    super.dispose();
  }

  void _follow() =>
      widget.visible.value ? _reveal.forward() : _reveal.reverse();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, child) => ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: _reveal.value,
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
