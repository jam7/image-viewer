import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/server_config.dart';

final _log = Logger('SmbConfigStore');

/// SMB接続設定の永続化。
/// 接続情報はJSONファイル、パスワードはflutter_secure_storageに保存。
class SmbConfigStore {
  late File _file;
  final Map<String, ServerConfig> _configs = {};
  final FlutterSecureStorage _secureStorage;
  bool _initialized = false;

  SmbConfigStore({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/config');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _file = File('${dir.path}/smb_configs.json');
    await _load();
    _initialized = true;
  }

  List<ServerConfig> listAll() {
    return _configs.values.toList();
  }

  ServerConfig? get(String id) => _configs[id];

  Future<void> save(ServerConfig config, String password) async {
    if (!_initialized) return;
    _configs[config.id] = config;
    await _secureStorage.write(
      key: 'smb_password_${config.id}',
      value: password,
    );
    await _flush();
  }

  Future<void> delete(String id) async {
    if (!_initialized) return;
    _configs.remove(id);
    await _secureStorage.delete(key: 'smb_password_$id');
    await _flush();
  }

  Future<String?> getPassword(String id) {
    return _secureStorage.read(key: 'smb_password_$id');
  }

  Future<void> _flush() async {
    final data = {
      'configs': {
        for (final e in _configs.entries) e.key: e.value.toJson(),
      },
    };
    final tmpFile = File('${_file.path}.tmp');
    await tmpFile.writeAsString(jsonEncode(data), flush: true);
    try {
      await tmpFile.rename(_file.path);
    } catch (e, st) {
      _log.warning('flush error', e, st);
    }
  }

  Future<void> _load() async {
    if (!_file.existsSync()) return;
    try {
      final content = await _file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final configs = data['configs'] as Map<String, dynamic>? ?? {};
      _configs.clear();
      for (final entry in configs.entries) {
        _configs[entry.key] = ServerConfig.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    } catch (e, st) {
      _log.warning('load error', e, st);
      _configs.clear();
    }
  }
}
