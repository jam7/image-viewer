import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../../services/cache/cache_manager.dart';
import 'system_back.dart';
import '../../services/smb/smb_config_store.dart';
import '../../services/sources/home_source.dart';
import '../settings/smb_connection_dialog.dart';
import 'gallery_session.dart';
import 'gallery_tab.dart';
import 'gallery_uri.dart';

/// A session on the landing page. Built directly rather than through the
/// registry: home needs no connection and no login, so there is nothing to
/// resolve and nothing that can fail.
GallerySession homeSession(CacheManager cacheManager) => GallerySession.fromUri(
      homeGalleryUri(),
      provider: HomeSource(),
      cacheManager: cacheManager,
      title: 'ホーム',
    );

/// The landing page as the content of a tab: the services and the registered
/// servers, plus the editing of those servers.
///
/// It is a place, not a listing — nothing to page through, nothing to give a
/// thumbnail — so it is the one body that does not go through `GalleryView`.
/// What it shares with the others is how you leave: a tap follows a link into
/// this tab's history, so back comes home here.
class HomeGalleryBody extends StatefulWidget {
  final GalleryTab tab;
  final SmbConfigStore smbConfigStore;

  /// Go to a place from here. [inNewTab] false follows it in this tab, which is
  /// what a tap means; true opens it alongside, which is what a long press
  /// means. Same shape the favorites list uses.
  final void Function(Uri uri, String title, {bool inNewTab}) onOpenPlace;

  /// Open the settings screen. Not an [onOpenPlace] because settings is not a
  /// place: it has no URI, nothing to go back to within it, and it lives on top
  /// of the tabs rather than inside one.
  final VoidCallback onOpenSettings;

  const HomeGalleryBody({
    super.key,
    required this.tab,
    required this.smbConfigStore,
    required this.onOpenPlace,
    required this.onOpenSettings,
  });

  @override
  State<HomeGalleryBody> createState() => _HomeGalleryBodyState();
}

class _HomeGalleryBodyState extends State<HomeGalleryBody> {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The same rule every body follows: walk the history while there is any,
      // then leave the app without ending it. Home is not special — it only
      // looked that way while back could close a tab.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleSystemBack(widget.tab, () => setState(() {}));
      },
      // Grouped by what the entries are, because that decides what tapping one
      // does. Services and servers are out there and have to be reached;
      // the library is already yours. Settings is none of the three — it is not
      // a place at all — so it sits below them as a plain row rather than
      // pretending to be another destination.
      child: ListView(
        children: [
          _section('サービス', _buildServices()),
          _section('サーバー', _buildServers(), action: _addSmbConfig),
          _section('ライブラリ', _buildLibrary()),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('設定'),
            onTap: widget.onOpenSettings,
          ),
        ],
      ),
    );
  }

  Widget _section(String title, Widget child, {VoidCallback? action}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (action != null) ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: action,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('追加'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildServices() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _ServiceCard(
          icon: Icons.palette,
          name: 'Pixiv',
          color: Colors.blue,
          onTap: () => widget.onOpenPlace(pixivGalleryUri('/top'), 'Pixiv'),
          onLongPress: () => widget
              .onOpenPlace(pixivGalleryUri('/top'), 'Pixiv', inNewTab: true),
        ),
        _ServiceCard(
          icon: Icons.shopping_bag,
          name: 'DMM',
          color: Colors.red.shade700,
          enabled: false,
        ),
        _ServiceCard(
          icon: Icons.store,
          name: 'DLsite',
          color: Colors.green.shade700,
          enabled: false,
        ),
      ],
    );
  }

  /// What is already yours, wherever it came from. Downloads (`dl://`) and a
  /// history belong here too once they exist.
  Widget _buildLibrary() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _ServiceCard(
          icon: Icons.favorite,
          name: 'お気に入り',
          color: Colors.pink,
          onTap: () => widget.onOpenPlace(favGalleryUri(), 'お気に入り'),
          onLongPress: () =>
              widget.onOpenPlace(favGalleryUri(), 'お気に入り', inNewTab: true),
        ),
      ],
    );
  }

  Widget _buildServers() {
    final configs = widget.smbConfigStore.listAll();
    if (configs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('サーバーが登録されていません', style: TextStyle(color: Colors.grey)),
      );
    }
    return Column(
      children: [
        for (final config in configs)
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_shared),
              title: Text(config.name),
              subtitle: Text('${config.host}/${config.shareName}'),
              onTap: () => _open(config),
              onLongPress: () => _open(config, inNewTab: true),
              trailing: PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'edit') _editSmbConfig(config);
                  if (action == 'delete') _deleteSmbConfig(config);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('編集')),
                  const PopupMenuItem(value: 'delete', child: Text('削除')),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _open(ServerConfig config, {bool inNewTab = false}) => widget.onOpenPlace(
        smbGalleryUri(config.id, config.basePath ?? '/'),
        config.name,
        inNewTab: inNewTab,
      );

  Future<void> _addSmbConfig() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const SmbConnectionDialog(),
    );
    if (result == null) return;
    await widget.smbConfigStore.save(
      result['config'] as ServerConfig,
      result['password'] as String,
    );
    if (mounted) setState(() {});
  }

  Future<void> _editSmbConfig(ServerConfig config) async {
    final password = await widget.smbConfigStore.getPassword(config.id);
    if (!mounted) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SmbConnectionDialog(
        existing: config,
        existingPassword: password,
      ),
    );
    if (result == null) return;
    await widget.smbConfigStore.save(
      result['config'] as ServerConfig,
      result['password'] as String,
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteSmbConfig(ServerConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認'),
        content: Text('「${config.name}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.smbConfigStore.delete(config.id);
    if (mounted) setState(() {});
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;

  const _ServiceCard({
    required this.icon,
    required this.name,
    required this.color,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      height: 80,
      child: Card(
        color: enabled ? null : Colors.grey.shade200,
        child: InkWell(
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 32, color: enabled ? color : Colors.grey),
              const SizedBox(height: 4),
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  color: enabled ? null : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
