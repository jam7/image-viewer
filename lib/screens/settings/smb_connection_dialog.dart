import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';

import '../../models/image_source.dart';
import '../../models/server_config.dart';

/// SMB接続設定の追加・編集ダイアログ。
class SmbConnectionDialog extends StatefulWidget {
  final ServerConfig? existing;
  final String? existingPassword;

  const SmbConnectionDialog({
    super.key,
    this.existing,
    this.existingPassword,
  });

  @override
  State<SmbConnectionDialog> createState() => _SmbConnectionDialogState();
}

class _SmbConnectionDialogState extends State<SmbConnectionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _shareController;
  late final TextEditingController _userController;
  late final TextEditingController _passwordController;
  late final TextEditingController _basePathController;
  String? _testResult;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _hostController = TextEditingController(text: e?.host ?? '');
    _portController = TextEditingController(text: '${e?.port ?? 445}');
    _shareController = TextEditingController(text: e?.shareName ?? '');
    _userController = TextEditingController(text: e?.username ?? '');
    _passwordController = TextEditingController(text: widget.existingPassword ?? '');
    _basePathController = TextEditingController(text: e?.basePath ?? '/');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _shareController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _basePathController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    try {
      final client = await Smb2Client.connect(
        host: _hostController.text.trim(),
        port: int.tryParse(_portController.text.trim()) ?? 445,
        username: _userController.text.trim(),
        password: _passwordController.text,
      );
      try {
        final share = _shareController.text.trim();
        final tree = await client.connectTree(share);
        final files = await tree.listDirectory('/');
        setState(() {
          _testResult = '接続成功 (${files.length}個のエントリを検出)';
        });
      } finally {
        await client.disconnect();
      }
    } catch (e, st) {
      print('[SMB] Test connection error: $e\n$st');
      final message = e is Exception ? e.toString() : e.runtimeType.toString();
      setState(() {
        _testResult = '接続失敗: $message';
      });
    } finally {
      setState(() => _isTesting = false);
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final id = widget.existing?.id ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final config = ServerConfig(
      id: id,
      name: _nameController.text.trim().isEmpty
          ? _hostController.text.trim()
          : _nameController.text.trim(),
      type: ImageSourceType.smb,
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 445,
      username: _userController.text.trim(),
      shareName: _shareController.text.trim(),
      basePath: _basePathController.text.trim().isEmpty
          ? '/'
          : _basePathController.text.trim(),
    );

    Navigator.of(context).pop({
      'config': config,
      'password': _passwordController.text,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing != null ? 'SMB接続を編集' : 'SMB接続を追加'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '名前（任意）'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _hostController,
                  decoration: const InputDecoration(labelText: 'ホスト'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '必須' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _portController,
                  decoration: const InputDecoration(labelText: 'ポート'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _shareController,
                  decoration: const InputDecoration(labelText: '共有名'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '必須' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _userController,
                  decoration: const InputDecoration(labelText: 'ユーザー名'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'パスワード'),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _basePathController,
                  decoration: const InputDecoration(labelText: 'ベースパス'),
                ),
                const SizedBox(height: 16),
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        color: _testResult!.startsWith('接続成功')
                            ? Colors.green
                            : Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isTesting ? null : _testConnection,
          child: _isTesting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('テスト接続'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
