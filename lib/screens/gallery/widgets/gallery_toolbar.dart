import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gallery_constants.dart';
import '../gallery_tab.dart';
import '../gallery_uri_dialect.dart';

/// What the page-count filter offers, in pages. 0 is "all of them".
const _pageCountChoices = [0, 3, 5, 10, 20];

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

  /// The search this edit would issue, carrying any switches flipped since it
  /// began — not the place the tab is on.
  ///
  /// Keeping them apart is what stops a switch corrupting where we are: an
  /// author page is not a search, and writing `?s_mode=` onto it produced an
  /// address the provider could not read. Options belong to the search.
  late Uri _pendingSearch;

  /// Set while an edit is opening: focus lands a frame or more after the text
  /// does, and arriving can move the caret, so the selection is restated then.
  bool _selectOnFocus = false;

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

  /// Tapping in offers whatever this place is worth editing — on a search the
  /// word, elsewhere the address — selected whole, so it can be replaced by
  /// typing. The address itself is in the menu, for taking somewhere else.
  void _beginEditing() {
    // A search issued from here starts as the one already on screen, so its
    // switches read the way the results were fetched.
    _pendingSearch = searchFrom(_uri, '') ?? _uri;
    _controller.text = editableOf(_uri);
    _selectOnFocus = true;
    setState(() => _editing = true);
    // Ask for focus rather than declaring `autofocus` on the field. Autofocus
    // is a request a scope may decline, and it declines whenever something in
    // it is already focused — which on every tab but home is the grid, holding
    // focus for its scroll keys. The symptom was a first tap that changed the
    // window but brought up no keyboard. An explicit request is not declined.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focus.requestFocus();
    });
  }

  void _selectAll() => _controller.selection =
      TextSelection(baseOffset: 0, extentOffset: _controller.text.length);

  /// Flip one of the search switches: it changes the search about to be made,
  /// and nothing about where we are.
  void _applyOption(SearchOption option) =>
      setState(() => _pendingSearch = option.next);

  void _endEditing() {
    if (!_editing) return;
    _selectOnFocus = false;
    setState(() => _editing = false);
    _focus.unfocus();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    // Looking away is the same as pressing Escape — an abandoned edit, not a
    // half-typed address to keep hold of.
    if (!_focus.hasFocus) {
      _endEditing();
      return;
    }
    if (!_selectOnFocus) return; // a later tap is the reader placing a caret
    _selectOnFocus = false;
    _selectAll();
  }

  /// What was typed decides what happens: an address goes there, anything else
  /// is a search of the source we are on. A source with no search drops it,
  /// which the hint text warned about before a key was pressed.
  ///
  /// Nothing typed means nothing asked for. The field starts empty on most
  /// places now, so this is the ordinary way an edit ends — and a search for
  /// no word is not a place at all.
  void _submit(String text) {
    final asked = text.trim();
    final place = asked.isEmpty
        ? null
        : parsePlace(asked) ?? searchFrom(_pendingSearch, asked);
    _endEditing();
    if (place != null) widget.onNavigate(place);
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: galleryHeaderRowHeight,
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
    return Container(
      height: 32,
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.symmetric(horizontal: _editing ? 4 : 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: _editing ? _buildEditor() : _buildLabel(),
    );
  }

  /// The resting window: where we are, and — where the notion means anything —
  /// how much of the list is being hidden. The filter is a sibling of the
  /// label, not inside it, so tapping it does not also start an edit.
  Widget _buildLabel() {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _beginEditing,
            child: Text(
              placeTitle(_uri, widget.tab.current.title),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        if (hasPageCounts(_uri)) _buildPageCountFilter(),
      ],
    );
  }

  Widget _buildEditor() {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _endEditing},
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                hintText: searchHintFor(_uri) ?? 'URI を入力',
                hintStyle: const TextStyle(fontSize: 13),
              ),
              textInputAction: TextInputAction.go,
              onSubmitted: _submit,
            ),
          ),
          // Only while a search is being typed: on a tab that cannot search,
          // or one just being read, these would be switches for nothing.
          for (final option in searchOptionsFor(_pendingSearch))
            _buildOption(option),
        ],
      ),
    );
  }

  /// Off, it is an icon. On, it is the number itself — because the accident
  /// this filter invites is forgetting it is there and taking a short list for
  /// the whole list. What is hiding items should say so while it hides them.
  Widget _buildPageCountFilter() {
    final min = widget.tab.current.minPageCount;
    return PopupMenuButton<int>(
      tooltip: 'ページ数で絞る',
      onSelected: (value) => widget.tab.current.minPageCount = value,
      itemBuilder: (_) => [
        for (final choice in _pageCountChoices)
          CheckedPopupMenuItem(
            value: choice,
            checked: choice == min,
            child: Text(choice == 0 ? 'すべて' : '$choice+'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: min == 0
            ? const Icon(Icons.filter_list, size: 18)
            : Text('$min+',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
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
      Size.fromHeight(strip.preferredSize.height + galleryHeaderRowHeight);

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: [strip, toolbar]);
}
