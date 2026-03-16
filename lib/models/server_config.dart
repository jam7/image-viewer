import 'image_source.dart';

/// サーバー接続情報。
class ServerConfig {
  final String id;
  final String name;
  final ImageSourceType type;
  final String host;
  final int port;
  final String? username;
  final String? shareName;
  final String? basePath;

  const ServerConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    this.port = 445,
    this.username,
    this.shareName,
    this.basePath,
  });

  /// JSONシリアライズ（パスワードは除外）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'shareName': shareName,
        'basePath': basePath,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      type: ImageSourceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => ImageSourceType.smb,
      ),
      host: json['host'] as String,
      port: json['port'] as int? ?? 445,
      username: json['username'] as String?,
      shareName: json['shareName'] as String?,
      basePath: json['basePath'] as String?,
    );
  }

  ServerConfig copyWith({
    String? id,
    String? name,
    ImageSourceType? type,
    String? host,
    int? port,
    String? username,
    String? shareName,
    String? basePath,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      shareName: shareName ?? this.shareName,
      basePath: basePath ?? this.basePath,
    );
  }
}
