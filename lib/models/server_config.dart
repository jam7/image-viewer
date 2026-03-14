import 'image_source.dart';

/// サーバー接続情報。
class ServerConfig {
  final String name;
  final ImageSourceType type;
  final String host;
  final int? port;
  final String? username;
  final String? password;
  final String? basePath;

  const ServerConfig({
    required this.name,
    required this.type,
    required this.host,
    this.port,
    this.username,
    this.password,
    this.basePath,
  });
}
