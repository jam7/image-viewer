import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/smb/smb_config_store.dart';
import '../../services/sources/pixiv_source.dart';
import '../../services/sources/smb_source.dart';
import '../gallery/gallery_screen.dart';
import '../gallery/smb_gallery_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/smb_connection_dialog.dart';
import 'favorites_tab.dart';

/// ランディングページ。下部タブバーでホームとお気に入りを切り替え。
class HomeScreen extends StatefulWidget {
  final PixivSource pixivSource;
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SmbConfigStore smbConfigStore;

  const HomeScreen({
    super.key,
    required this.pixivSource,
    required this.cacheManager,
    required this.favoritesStore,
    required this.smbConfigStore,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentTab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _currentTab == 0 ? _buildHomeTab() : FavoritesTab(
        favoritesStore: widget.favoritesStore,
        cacheManager: widget.cacheManager,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() => _currentTab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'ホーム',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_outline),
            selectedIcon: Icon(Icons.favorite),
            label: 'お気に入り',
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: const Text('Image Viewer'),
          floating: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _openSettings,
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: _buildServicesSection(),
        ),
        SliverToBoxAdapter(
          child: _buildServersSection(),
        ),
      ],
    );
  }

  Widget _buildServicesSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'サービス',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _ServiceCard(
                icon: Icons.palette,
                name: 'Pixiv',
                color: Colors.blue,
                onTap: _openPixiv,
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
          ),
        ],
      ),
    );
  }

  Widget _buildServersSection() {
    final configs = widget.smbConfigStore.listAll();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'サーバー',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _addSmbConfig,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('追加'),
              ),
            ],
          ),
          if (configs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('サーバーが登録されていません', style: TextStyle(color: Colors.grey)),
            )
          else
            for (final config in configs)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_shared),
                  title: Text(config.name),
                  subtitle: Text('${config.host}/${config.shareName}'),
                  onTap: () => _connectSmb(config),
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
      ),
    );
  }

  void _openPixiv() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        source: widget.pixivSource,
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
      ),
    ));
  }

  Future<void> _connectSmb(ServerConfig config) async {
    final password = await widget.smbConfigStore.getPassword(config.id);
    if (password == null) return;
    if (!mounted) return;
    final source = SmbSource(config: config, password: password);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SmbGalleryScreen(
        source: source,
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        initialPath: config.basePath ?? '/',
      ),
    ));
  }

  Future<void> _addSmbConfig() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const SmbConnectionDialog(),
    );
    if (result == null) return;
    final config = result['config'] as ServerConfig;
    final password = result['password'] as String;
    await widget.smbConfigStore.save(config, password);
    setState(() {});
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
    final newConfig = result['config'] as ServerConfig;
    final newPassword = result['password'] as String;
    await widget.smbConfigStore.save(newConfig, newPassword);
    setState(() {});
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
    setState(() {});
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        cacheManager: widget.cacheManager,
        favoritesStore: widget.favoritesStore,
        smbConfigStore: widget.smbConfigStore,
      ),
    ));
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final Color color;
  final VoidCallback? onTap;
  final bool enabled;

  const _ServiceCard({
    required this.icon,
    required this.name,
    required this.color,
    this.onTap,
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
