import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gallery_tab.dart';
import '../gallery_uri_dialect.dart';

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
/// The toolbar walks [tab]'s history itself, the way the strip works the
/// controller. [onNavigate] is only for the address field, whose destination is
/// not in the history yet and may need the source resolving first.
class GalleryToolbar extends StatefulWidget {
  static const height = 44.0;

  final GalleryTab tab;
  final ValueChanged<Uri> onNavigate;

  /// The menu, in groups shown with a rule between them: this tab's own places
  /// on top, what to do with the app below. Empty groups are left out.
  final List<List<ToolbarMenuItem>> menuGroups;

  const GalleryToolbar({
    super.key,
    required this.tab,
    required this.onNavigate,
    this.menuGroups = const [],
  });

  @override
  State<GalleryToolbar> createState() => _GalleryToolbarState();
}

class _GalleryToolbarState extends State<GalleryToolbar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  /// Where the edit started from, carrying any switches flipped since. A search
  /// typed into the field is issued from here rather than from the tab, so the
  /// options are the ones on screen.
  late Uri _base;

  Uri get _uri => widget.tab.current.sourceUri;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(GalleryToolbar old) {
    super.didUpdateWidget(old);
    // Switching tabs while typing: the text was about the tab that left.
    if (widget.tab.id != old.tab.id) _endEditing();
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Tapping in shows the address rather than the title, selected whole: it is
  /// the thing worth copying, and copying it needs no feature of ours beyond
  /// having put it somewhere selectable.
  void _beginEditing() {
    _base = _uri;
    final address = '$_base';
    _controller.value = TextEditingValue(
      text: address,
      selection: TextSelection(baseOffset: 0, extentOffset: address.length),
    );
    setState(() => _editing = true);
  }

  /// Flip one of the search switches. The address is where the options live, so
  /// the field is rewritten to match — unless a word has been typed over it, in
  /// which case the new options are simply what that word will be searched with.
  void _applyOption(SearchOption option) {
    setState(() => _base = option.next);
    if (parsePlace(_controller.text) == null) return;
    _controller.value = TextEditingValue(
      text: '$_base',
      selection: TextSelection.collapsed(offset: '$_base'.length),
    );
  }

  void _endEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
    _focus.unfocus();
  }

  void _onFocusChanged() {
    // Looking away is the same as pressing Escape — an abandoned edit, not a
    // half-typed address to keep hold of.
    if (mounted && !_focus.hasFocus) _endEditing();
  }

  /// What was typed decides what happens: an address goes there, anything else
  /// is a search of the source we are on. A source with no search drops it,
  /// which the hint text warned about before a key was pressed.
  void _submit(String text) {
    final place = parsePlace(text) ?? searchFrom(_base, text.trim());
    _endEditing();
    if (place != null) widget.onNavigate(place);
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: GalleryToolbar.height,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: '戻る',
              // Dead at the first entry rather than closing the tab: back must
              // not be able to throw a history away (ADR 009 追記).
              onPressed: tab.canGoBack ? tab.back : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward, size: 20),
              tooltip: '進む',
              onPressed: tab.canGoForward ? tab.forward : null,
            ),
            Expanded(child: _buildAddressField(context)),
            if (_menuEntries().isEmpty)
              const SizedBox(width: 8)
            else
              _buildMenuButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildAddressField(BuildContext context) {
    final field = Container(
      height: 32,
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.symmetric(horizontal: _editing ? 4 : 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: _editing ? _buildEditor() : _buildLabel(),
    );
    if (_editing) return field;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _beginEditing,
      child: field,
    );
  }

  Widget _buildLabel() => Text(
        placeTitle(_uri, widget.tab.current.title),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: const TextStyle(fontSize: 13),
      );

  Widget _buildEditor() {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _endEditing},
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                hintText: searchHintFor(_base) ?? 'URI を入力',
                hintStyle: const TextStyle(fontSize: 13),
              ),
              textInputAction: TextInputAction.go,
              onSubmitted: _submit,
            ),
          ),
          // Only while a search is being typed: on a tab that cannot search,
          // or one just being read, these would be switches for nothing.
          for (final option in searchOptionsFor(_base)) _buildOption(option),
        ],
      ),
    );
  }

  Widget _buildOption(SearchOption option) {
    return InkWell(
      onTap: () => _applyOption(option),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(option.label, style: const TextStyle(fontSize: 11)),
      ),
    );
  }

  /// The menu, with a rule wherever one group of entries gives way to the next.
  List<PopupMenuEntry<ToolbarMenuItem>> _menuEntries() {
    final entries = <PopupMenuEntry<ToolbarMenuItem>>[];
    for (final group in widget.menuGroups.where((g) => g.isNotEmpty)) {
      if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
      for (final item in group) {
        entries.add(PopupMenuItem(
          value: item,
          child: Row(
            children: [
              Icon(item.icon, size: 20),
              const SizedBox(width: 12),
              Text(item.label),
            ],
          ),
        ));
      }
    }
    return entries;
  }

  Widget _buildMenuButton() {
    return PopupMenuButton<ToolbarMenuItem>(
      icon: const Icon(Icons.menu, size: 20),
      tooltip: 'メニュー',
      onSelected: (item) => item.onSelected(),
      itemBuilder: (_) => _menuEntries(),
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
