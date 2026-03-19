/// リモート画像の所在を表すモデル。
/// プロトコルに依存しない共通表現。
class ImageSource {
  final String id;
  final String name;
  final String uri;
  final ImageSourceType type;
  final String? sourceKey; // e.g. "pixiv:default", "smb:1773662275240"
  final Map<String, dynamic>? metadata;

  const ImageSource({
    required this.id,
    required this.name,
    required this.uri,
    required this.type,
    this.sourceKey,
    this.metadata,
  });
}

enum ImageSourceType {
  http,
  smb,
  googleDrive,
  oneDrive,
  pixiv,
}
