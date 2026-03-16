import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../../services/cache/cache_manager.dart';
import '../../services/cache/cache_metadata.dart';
import '../../services/favorites/favorites_store.dart';
import '../../services/smb/smb_config_store.dart';
import 'smb_connection_dialog.dart';

/// キャッシュ・DL・お気に入り・接続先管理画面。
class SettingsScreen extends StatefulWidget {
  final CacheManager cacheManager;
  final FavoritesStore favoritesStore;
  final SmbConfigStore smbConfigStore;
  final void Function(ServerConfig config, String password)? onSmbConnect;

  const SettingsScreen({
    super.key,
    required this.cacheManager,
    required this.favoritesStore,
    required this.smbConfigStore,
    this.onSmbConnect,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  CacheStats? _l2Stats;
  CacheStats? _l3Stats;
  int _favCount = 0;
  late double _l2MaxSizeGB;

  @override
  void initState() {
    super.initState();
    _l2MaxSizeGB = widget.cacheManager.l2.maxSizeBytes / (1024 * 1024 * 1024);
    _loadStats();
  }

  Future<void> _loadStats() async {
    final l2 = await widget.cacheManager.getL2Stats();
    final l3 = await widget.cacheManager.getL3Stats();
    setState(() {
      _l2Stats = l2;
      _l3Stats = l3;
      _favCount = widget.favoritesStore.count;
    });
  }

  Future<void> _clearL2() async {
    final confirmed = await _showConfirmDialog('中期キャッシュをクリアしますか？');
    if (confirmed != true) return;
    await widget.cacheManager.clearL2();
    await _loadStats();
  }

  Future<void> _clearL3() async {
    final confirmed = await _showConfirmDialog('ダウンロード済みの画像をすべて削除しますか？');
    if (confirmed != true) return;
    await widget.cacheManager.clearL3();
    await _loadStats();
  }

  Future<void> _clearFavorites() async {
    final confirmed = await _showConfirmDialog('お気に入りをすべて削除しますか？');
    if (confirmed != true) return;
    await widget.favoritesStore.clear();
    await _loadStats();
  }

  void _onL2MaxSizeChanged(double value) {
    setState(() => _l2MaxSizeGB = value);
    final bytes = (value * 1024 * 1024 * 1024).round();
    widget.cacheManager.setL2MaxSize(bytes);
  }

  Future<bool?> _showConfirmDialog(String message) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認'),
        content: Text(message),
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const _SectionHeader('SMB接続'),
          _buildSmbSection(),
          const Divider(),
          const _SectionHeader('キャッシュ管理'),
          _buildL2Section(),
          const Divider(),
          _buildL3Section(),
          const Divider(),
          _buildFavoritesSection(),
        ],
      ),
    );
  }

  Widget _buildL2Section() {
    final stats = _l2Stats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('中期キャッシュ',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (stats != null) ...[
            Text('${stats.formattedSize} / ${stats.formattedMaxSize}'
                '  (${stats.itemCount}枚)'),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: stats.usageRatio.clamp(0.0, 1.0),
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
          ] else
            const Text('読み込み中...'),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('サイズ上限: '),
              Expanded(
                child: Slider(
                  value: _l2MaxSizeGB,
                  min: 0.5,
                  max: 5.0,
                  divisions: 9,
                  label: '${_l2MaxSizeGB.toStringAsFixed(1)} GB',
                  onChanged: _onL2MaxSizeChanged,
                ),
              ),
              Text('${_l2MaxSizeGB.toStringAsFixed(1)} GB'),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearL2,
              icon: const Icon(Icons.delete_outline),
              label: const Text('クリア'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildL3Section() {
    final stats = _l3Stats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ダウンロード',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (stats != null)
            Text('${stats.formattedSize}  (${stats.itemCount}枚)')
          else
            const Text('読み込み中...'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearL3,
              icon: const Icon(Icons.delete_outline),
              label: const Text('クリア'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('お気に入り',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('$_favCount件登録'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearFavorites,
              icon: const Icon(Icons.delete_outline),
              label: const Text('クリア'),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildSmbSection() {
    final configs = widget.smbConfigStore.listAll();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final config in configs)
            ListTile(
              leading: const Icon(Icons.folder_shared),
              title: Text(config.name),
              subtitle: Text('${config.host}/${config.shareName}'),
              onTap: () => _connectSmb(config),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: () => _editSmbConfig(config),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteSmbConfig(config),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _addSmbConfig,
              icon: const Icon(Icons.add),
              label: const Text('追加'),
            ),
          ),
        ],
      ),
    );
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
    final confirmed = await _showConfirmDialog('「${config.name}」を削除しますか？');
    if (confirmed != true) return;
    await widget.smbConfigStore.delete(config.id);
    setState(() {});
  }

  Future<void> _connectSmb(ServerConfig config) async {
    final password = await widget.smbConfigStore.getPassword(config.id);
    print('[Settings] connectSmb: config=${config.id}, password=${password != null ? '***' : 'null'}, callback=${widget.onSmbConnect != null}');
    if (password == null) {
      print('[Settings] No password found for ${config.id}');
      return;
    }
    widget.onSmbConnect?.call(config, password);
    if (mounted) Navigator.of(context).pop();
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
