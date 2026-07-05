import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared keyboard / scroll / mouse-back / swipe scaffolding for the gallery
/// screens. Extracted from `GalleryScreen` (Pixiv) and `SmbGalleryScreen` after
/// their input behavior was unified (see docs/gallery_unification/design.md).
///
/// Scroll keys are handled only while the grid has scroll clients and
/// [focusNode] holds primary focus (so typing in the search / filter fields is
/// not treated as navigation):
/// - Down / Up: scroll by 100px
/// - PageDown / Space, PageUp: scroll by 90% of the viewport
/// - Home / End: jump to top / bottom
///
/// Escape / Backspace, the mouse back button, and a rightward horizontal swipe
/// all invoke [onPop].
class GalleryKeyboardScrollable extends StatelessWidget {
  final FocusNode focusNode;
  final ScrollController scrollController;
  final VoidCallback onPop;
  final Widget child;

  const GalleryKeyboardScrollable({
    super.key,
    required this.focusNode,
    required this.scrollController,
    required this.onPop,
    required this.child,
  });

  void _scrollBy(double delta) {
    if (!scrollController.hasClients) return;
    scrollController.animateTo(
      (scrollController.offset + delta).clamp(
        0.0,
        scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (FocusManager.instance.primaryFocus != focusNode) {
      return KeyEventResult.ignored;
    }
    if (!scrollController.hasClients) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final viewportHeight = scrollController.position.viewportDimension;

    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(100);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-100);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.space) {
      _scrollBy(viewportHeight * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _scrollBy(-viewportHeight * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _scrollBy(-scrollController.offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _scrollBy(
          scrollController.position.maxScrollExtent - scrollController.offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace) {
      onPop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) onPop();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 300) onPop();
          },
          child: child,
        ),
      ),
    );
  }
}
