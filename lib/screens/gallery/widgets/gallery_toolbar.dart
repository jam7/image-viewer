import 'package:flutter/material.dart';

/// One entry in the toolbar's menu.
class ToolbarMenuItem {
  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  const ToolbarMenuItem({
    required this.label,
    required this.icon,
    required this.onSelected,
  });
}

/// The navigation row under the tab strip (ADR 009): back, forward, where you
/// are, and the menu.
///
/// Back and forward are on screen rather than on a gesture because Android 15
/// has no back button and has taken the screen edges for predictive back —
/// there is nothing left to long-press and no edge to swipe. Showing them also
/// makes forward, which never had an input at all, reachable.
///
/// [title] is where the tab is now. It becomes an address bar in 2C-2; for the
/// moment it only shows, which is already more than the tab chip can fit.
class GalleryToolbar extends StatelessWidget {
  static const height = 44.0;

  final String title;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final List<ToolbarMenuItem> menuItems;

  const GalleryToolbar({
    super.key,
    required this.title,
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    this.menuItems = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: '戻る',
              onPressed: canGoBack ? onBack : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward, size: 20),
              tooltip: '進む',
              onPressed: canGoForward ? onForward : null,
            ),
            Expanded(child: _buildAddressField(context)),
            if (menuItems.isEmpty)
              const SizedBox(width: 8)
            else
              _buildMenuButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildAddressField(BuildContext context) {
    return Container(
      height: 32,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        title,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildMenuButton() {
    return PopupMenuButton<ToolbarMenuItem>(
      icon: const Icon(Icons.menu, size: 20),
      tooltip: 'メニュー',
      onSelected: (item) => item.onSelected(),
      itemBuilder: (_) => [
        for (final item in menuItems)
          PopupMenuItem(
            value: item,
            child: Row(
              children: [
                Icon(item.icon, size: 20),
                const SizedBox(width: 12),
                Text(item.label),
              ],
            ),
          ),
      ],
    );
  }
}

/// The two header rows as one app bar: the tab strip over the toolbar.
///
/// They are an app bar rather than part of the body so that the strip keeps its
/// state — most visibly its scroll position — while the body underneath is
/// rebuilt for each tab.
class GalleryHeader extends StatelessWidget implements PreferredSizeWidget {
  final PreferredSizeWidget strip;
  final GalleryToolbar toolbar;

  const GalleryHeader({super.key, required this.strip, required this.toolbar});

  @override
  Size get preferredSize =>
      Size.fromHeight(strip.preferredSize.height + GalleryToolbar.height);

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: [strip, toolbar]);
}
