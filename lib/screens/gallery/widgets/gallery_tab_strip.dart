import 'package:flutter/material.dart';

import '../gallery_tab.dart';
import '../gallery_tab_controller.dart';
import '../gallery_uri.dart';

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
/// Labels are short because a full SMB path cannot fit in a chip: the active
/// tab gets one level of parent for context (`vol2\2`) and the rest just the
/// leaf (`2`). Pixiv chips show the current page's own title, which changes as
/// the tab is navigated. The icon says which source it came from, and the full
/// title is on the tooltip.
class GalleryTabStrip extends StatelessWidget implements PreferredSizeWidget {
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
  Widget build(BuildContext context) {
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
      message: session.title.isEmpty ? '${session.sourceUri}' : session.title,
      child: Material(
        color: selected ? scheme.surface : scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 160),
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
  static String _labelFor(Uri uri, String title, {required bool withParent}) {
    if (uri.scheme != smbUriScheme) {
      return title.isEmpty ? uri.toString() : title;
    }
    final path = smbPathOf(uri);
    if (path == '/') return uri.host;
    final segments = path.split(r'\').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return path;
    final keep = withParent && segments.length >= 2 ? 2 : 1;
    return segments.skip(segments.length - keep).join(r'\');
  }
}
