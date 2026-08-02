import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../models/server_config.dart';

final _log = Logger('SmbConnectionDialog');

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
  bool _isBenchmarking = false;
  bool _benchmarkCancelled = false;
  final List<String> _benchLines = [];

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
      _log.warning('Test connection error', e, st);
      final message = e is Exception ? e.toString() : e.runtimeType.toString();
      setState(() {
        _testResult = '接続失敗: $message';
      });
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _runBenchmark() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isBenchmarking = true;
      _benchmarkCancelled = false;
      _benchLines.clear();
      _testResult = null;
    });

    void log(String line) {
      if (!mounted || _benchmarkCancelled) return;
      setState(() => _benchLines.add(line));
    }

    Smb2Client? client;
    try {
      client = await Smb2Client.connect(
        host: _hostController.text.trim(),
        port: int.tryParse(_portController.text.trim()) ?? 445,
        username: _userController.text.trim(),
        password: _passwordController.text,
      );
      final tree = await client.connectTree(_shareController.text.trim());
      final basePath = _basePathController.text.trim().isEmpty
          ? '/' : _basePathController.text.trim();

      // Biggest first: the largest file is what the single-file run reads,
      // and the top of the list is what the parallel run works through.
      final files = await tree.listDirectory(basePath);
      final readable = files.where((f) => !f.isDirectory && f.size > 0).toList()
        ..sort((a, b) => b.size.compareTo(a.size));

      if (readable.isEmpty) {
        log('ファイルが見つかりません: $basePath');
        return;
      }

      await _benchReadAhead(tree, readable.first, log);
      if (_benchmarkCancelled) return;
      await _benchParallel(tree, readable.take(_benchFileCount).toList(), log);
      if (_benchmarkCancelled) return;
      log('');
      log('完了');
    } catch (e, st) {
      _log.warning('Benchmark error', e, st);
      log('エラー: $e');
    } finally {
      try {
        await client?.disconnect();
      } catch (e, st) {
        // Nothing left to do about it — the run is over either way — but a
        // share that will not let go is worth knowing about.
        _log.warning('disconnect error after benchmark', e, st);
      }
      if (mounted) setState(() => _isBenchmarking = false);
    }
  }

  /// The settings each run is measured at, and how much of the directory the
  /// parallel run reads.
  static const _benchSteps = [1, 2, 3, 5, 8];
  static const _benchFileCount = 20;

  /// How fast one file reads at each read-ahead depth.
  Future<void> _benchReadAhead(
    Smb2Tree tree,
    Smb2FileInfo target,
    void Function(String) log,
  ) async {
    log('=== Single file: ${target.name} '
        '(${(target.size / 1024).toStringAsFixed(0)} KB) ===');
    for (final readAhead in _benchSteps) {
      if (_benchmarkCancelled) return;
      final sw = Stopwatch()..start();
      final bytes = await _readWhole(tree, target.path, readAhead: readAhead);
      sw.stop();
      log('readAhead=$readAhead: ${_timing(bytes, sw)}');
    }
  }

  /// How fast a directory reads with several files in flight at once.
  Future<void> _benchParallel(
    Smb2Tree tree,
    List<Smb2FileInfo> files,
    void Function(String) log,
  ) async {
    final totalSize = files.fold<int>(0, (sum, f) => sum + f.size);
    log('');
    log('=== Parallel: ${files.length} files '
        '(${(totalSize / 1024).toStringAsFixed(0)} KB) ===');
    for (final width in _benchSteps) {
      if (_benchmarkCancelled) return;
      final sw = Stopwatch()..start();
      var bytes = 0;
      for (var i = 0; i < files.length; i += width) {
        if (_benchmarkCancelled) break;
        final batch = files.sublist(i, (i + width).clamp(0, files.length));
        final read = await Future.wait(
          batch.map((f) => _readWhole(tree, f.path, readAhead: 3)),
        );
        bytes += read.fold(0, (sum, n) => sum + n);
      }
      sw.stop();
      log('parallel=$width: ${_timing(bytes, sw)}');
    }
  }

  /// Read [path] to the end, answering how many bytes came back.
  ///
  /// Stops where it is if the run was cancelled: a benchmark is minutes of
  /// traffic, and the cancel button has to mean now rather than after this
  /// file.
  Future<int> _readWhole(
    Smb2Tree tree,
    String path, {
    required int readAhead,
  }) async {
    final reader = await tree.openRead(path);
    var total = 0;
    try {
      await for (final chunk in reader.readStream(readAhead: readAhead)) {
        total += chunk.length;
        if (_benchmarkCancelled) break;
      }
    } finally {
      await reader.close();
    }
    return total;
  }

  /// How long it took and how fast that was: `1.23s  4567 KB/s`.
  static String _timing(int bytes, Stopwatch sw) {
    final seconds = sw.elapsedMilliseconds / 1000;
    final rate = seconds > 0
        ? (bytes / 1024 / seconds).toStringAsFixed(0)
        : '?';
    return '${seconds.toStringAsFixed(2)}s  $rate KB/s';
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

  /// One line of the form, gap below included.
  ///
  /// The gap belongs to the field rather than to whoever lists them: there
  /// are seven, and a missing one is a dialog that looks slightly wrong in a
  /// way nobody can name. [required] is the same emptiness check each time —
  /// a host and a share are all this needs to try a connection.
  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        obscureText: obscure,
        keyboardType: keyboardType,
        validator: required
            ? (v) => v == null || v.trim().isEmpty ? '必須' : null
            : null,
      ),
    );
  }

  /// How the last connection attempt went, in one line.
  Widget? _testResultLine() {
    final result = _testResult;
    if (result == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        result,
        style: TextStyle(
          color: result.startsWith('接続成功') ? Colors.green : Colors.red,
          fontSize: 12,
        ),
      ),
    );
  }

  /// The benchmark's output as it arrives, in a box of its own so a long run
  /// scrolls instead of pushing the buttons off the dialog.
  Widget? _benchmarkLog() {
    if (_benchLines.isEmpty) return null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(4),
      ),
      constraints: const BoxConstraints(maxHeight: 200),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          _benchLines.join('\n'),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Colors.greenAccent,
          ),
        ),
      ),
    );
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
                _field(_nameController, '名前（任意）'),
                _field(_hostController, 'ホスト', required: true),
                _field(_portController, 'ポート',
                    keyboardType: TextInputType.number),
                _field(_shareController, '共有名', required: true),
                _field(_userController, 'ユーザー名'),
                _field(_passwordController, 'パスワード', obscure: true),
                _field(_basePathController, 'ベースパス'),
                // The last field brings 8 of its own; together the 16 that
                // sets the form apart from what is reported below it.
                const SizedBox(height: 8),
                ?_testResultLine(),
                ?_benchmarkLog(),
              ],
            ),
          ),
        ),
      ),
      actions: _actions(context),
    );
  }

  /// Both of the two things this dialog can do take a while and talk to the
  /// same server, so each button is also a statement about what the other one
  /// is doing: nothing but 中止 is available during a benchmark, and nothing
  /// at all while a connection is being tried.
  List<Widget> _actions(BuildContext context) {
    return [
      TextButton(
        onPressed: _isTesting || _isBenchmarking ? null : _testConnection,
        child: _isTesting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('テスト接続'),
      ),
      TextButton(
        onPressed: _isTesting
            ? null
            : _isBenchmarking
                ? () => setState(() => _benchmarkCancelled = true)
                : _runBenchmark,
        child: _isBenchmarking
            ? const Text('中止')
            : const Text('性能確認'),
      ),
      TextButton(
        onPressed: _isBenchmarking ? null : () => Navigator.of(context).pop(),
        child: const Text('キャンセル'),
      ),
      ElevatedButton(
        onPressed: _isBenchmarking ? null : _save,
        child: const Text('保存'),
      ),
    ];
  }
}
