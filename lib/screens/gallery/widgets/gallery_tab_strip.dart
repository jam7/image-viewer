import 'package:flutter/material.dart';

import '../gallery_tab.dart';
import '../gallery_tab_controller.dart';
import '../gallery_uri.dart';
import '../gallery_uri_dialect.dart';

/// One entry in the `+` menu: somewhere a new tab can be opened.
class NewTabOption {
  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  const NewTabOption({
    required this.label,
    required this.icon,
    required this.onSelected,
  });
}

/// The tab strip, standing in for the app bar rather than sitting under it.
///
/// Stacking a strip on top of an app bar costs a row of height, which is
/// expensive here: at five columns the 8-inch tablet shows fewer than three
/// rows of thumbnails in landscape. Merging them costs nothing.
///
/// Labels are short because a full path cannot fit in a chip: the active tab
/// gets one level of parent for context (`vol2/2`) and the rest just the leaf
/// (`2`). Pixiv chips show the current page's own title, which changes as the
/// tab is navigated. The icon says which source it came from, and the full
/// title is on the tooltip.
///
/// Paths are shown with `/` whatever the source separates them with, so that
/// every source reads the same as more are added.
class GalleryTabStrip extends StatefulWidget implements PreferredSizeWidget {
  final GalleryTabController controller;

  /// Places the `+` button offers.
  final List<NewTabOption> newTabOptions;

  /// Buttons pinned to the right, after `+` (e.g. the current source's menu).
  final List<Widget> actions;

  const GalleryTabStrip({
    super.key,
    required this.controller,
    this.newTabOptions = const [],
    this.actions = const [],
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<GalleryTabStrip> createState() => _GalleryTabStripState();
}

/// Widest a chip gets; also how far past the reported end a reveal aims.
const _chipMaxWidth = 160.0;

class _GalleryTabStripState extends State<GalleryTabStrip> {
  final _scrollController = ScrollController();

  /// Set eagerly in [initState]. A `late` initialiser would not run until the
  /// first comparison, by which time it would already hold the grown count and
  /// the growth would never be noticed.
  int _tabCount = 0;

  @override
  void initState() {
    super.initState();
    _tabCount = widget.controller.tabs.length;
  }

  @override
  void didUpdateWidget(GalleryTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.controller.tabs.length;
    // A tab was added. It goes on the end, which may be past the right edge —
    // and a tab opened in the background is invisible if the strip does not
    // move, so the one bit of feedback it has would be missed.
    if (count > _tabCount) _revealEnd();
    _tabCount = count;
  }

  void _revealEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      // Aim past the end rather than at it. The list only measures the chips it
      // has built, so the reported end is short of the real one while the new
      // chip is still off-screen; the physics clamp, so overshooting lands on
      // the real end instead of past it. One chip's width plus slack is enough.
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + _chipMaxWidth,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final newTabOptions = widget.newTabOptions;
    final actions = widget.actions;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: controller.tabs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (context, i) => _TabChip(
                    tab: controller.tabs[i],
                    selected: i == controller.activeIndex,
                    onTap: () => controller.select(i),
                    onClose: () => controller.close(i),
                  ),
                ),
              ),
              if (newTabOptions.isNotEmpty)
                PopupMenuButton<NewTabOption>(
                  icon: const Icon(Icons.add),
                  tooltip: '新しいタブ',
                  onSelected: (o) => o.onSelected(),
                  itemBuilder: (_) => [
                    for (final option in newTabOptions)
                      PopupMenuItem(
                        value: option,
                        child: Row(
                          children: [
                            Icon(option.icon, size: 20),
                            const SizedBox(width: 12),
                            Text(option.label),
                          ],
                        ),
                      ),
                  ],
                ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final GalleryTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TabChip({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = tab.current;
    return Tooltip(
      message: placeTitle(session.sourceUri, session.title),
      child: Material(
        color: selected ? scheme.surface : scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: _chipMaxWidth),
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_iconFor(session.sourceUri), size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _labelFor(session.sourceUri, session.title,
                        withParent: selected),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(Uri uri) => switch (uri.scheme) {
        smbUriScheme => Icons.folder,
        pixivUriScheme => Icons.palette,
        _ => Icons.tab,
      };

  /// The tail of the place. A directory's own name is often not enough to tell
  /// two tabs apart, so the one being shown gets its parent as well; the others
  /// stay narrow. Pixiv pages already carry a short title of their own.
  ///
  /// Read straight off the URI's segments, which are already `/`-separated
  /// whatever the source uses natively — no need to put SMB's backslashes back
  /// just to show them.
  static String _labelFor(Uri uri, String title, {required bool withParent}) {
    if (uri.scheme != smbUriScheme) return placeTitle(uri, title);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return uri.host; // the share root
    final keep = withParent && segments.length >= 2 ? 2 : 1;
    return segments.skip(segments.length - keep).join('/');
  }
}
