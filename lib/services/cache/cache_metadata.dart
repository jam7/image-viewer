/// キャッシュエントリのメタデータ（L2/L3共通）。
class CacheEntryMeta {
  final String key;
  final int sizeBytes;
  final DateTime lastAccessTime;
  final DateTime createdTime;

  CacheEntryMeta({
    required this.key,
    required this.sizeBytes,
    required this.lastAccessTime,
    required this.createdTime,
  });

  CacheEntryMeta copyWith({DateTime? lastAccessTime}) {
    return CacheEntryMeta(
      key: key,
      sizeBytes: sizeBytes,
      lastAccessTime: lastAccessTime ?? this.lastAccessTime,
      createdTime: createdTime,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'sizeBytes': sizeBytes,
        'lastAccessTime': lastAccessTime.toIso8601String(),
        'createdTime': createdTime.toIso8601String(),
      };

  factory CacheEntryMeta.fromJson(Map<String, dynamic> json) {
    return CacheEntryMeta(
      key: json['key'] as String,
      sizeBytes: json['sizeBytes'] as int,
      lastAccessTime: DateTime.parse(json['lastAccessTime'] as String),
      createdTime: DateTime.parse(json['createdTime'] as String),
    );
  }
}

/// お気に入りエントリ（URLとメタデータのみ、画像データなし）。
class FavoriteEntry {
  final String imageId;
  final String name;
  final String uri;
  final String? thumbnailUrl;
  final Map<String, dynamic> sourceInfo;
  final DateTime addedAt;

  const FavoriteEntry({
    required this.imageId,
    required this.name,
    required this.uri,
    this.thumbnailUrl,
    required this.sourceInfo,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'uri': uri,
        'thumbnailUrl': thumbnailUrl,
        'sourceInfo': sourceInfo,
        'addedAt': addedAt.toIso8601String(),
      };

  factory FavoriteEntry.fromJson(String imageId, Map<String, dynamic> json) {
    return FavoriteEntry(
      imageId: imageId,
      name: json['name'] as String? ?? '',
      uri: json['uri'] as String? ?? '',
      thumbnailUrl: json['thumbnailUrl'] as String?,
      sourceInfo: (json['sourceInfo'] as Map<String, dynamic>?) ?? {},
      addedAt: DateTime.parse(json['addedAt'] as String),
    );
  }
}

/// キャッシュの統計情報。
class CacheStats {
  final int totalSizeBytes;
  final int itemCount;
  final int maxSizeBytes;

  const CacheStats({
    required this.totalSizeBytes,
    required this.itemCount,
    required this.maxSizeBytes,
  });

  String get formattedSize => _formatBytes(totalSizeBytes);
  String get formattedMaxSize => _formatBytes(maxSizeBytes);

  double get usageRatio =>
      maxSizeBytes > 0 ? totalSizeBytes / maxSizeBytes : 0;

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// CacheManager が返す結果。どの層から取得したかを含む。
enum CacheSource { memory, disk, download, network }

class CacheResult {
  final List<int> data;
  final CacheSource source;

  const CacheResult(this.data, this.source);
}
