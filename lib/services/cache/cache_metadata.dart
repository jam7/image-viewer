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

  /// Written as numbers, and without the key: the index is a map already
  /// keyed by it.
  ///
  /// The shape is chosen for the cost of writing it. The whole index is
  /// rewritten whenever it changes, and at ten thousand entries the two dates
  /// as text were twenty thousand calls to [DateTime.toIso8601String] and half
  /// the bytes of the file — 90ms on the app's own thread, measured on the
  /// device (2026-08-02).
  Map<String, dynamic> toJson() => {
        'sizeBytes': sizeBytes,
        'lastAccessMs': lastAccessTime.millisecondsSinceEpoch,
        'createdMs': createdTime.millisecondsSinceEpoch,
      };

  /// [key] is where the index held this entry; an index written before the
  /// shape above also carries it, and its dates as ISO strings.
  factory CacheEntryMeta.fromJson(Map<String, dynamic> json, String key) {
    return CacheEntryMeta(
      key: json['key'] as String? ?? key,
      sizeBytes: json['sizeBytes'] as int,
      lastAccessTime: _when(json, 'lastAccessMs', 'lastAccessTime'),
      createdTime: _when(json, 'createdMs', 'createdTime'),
    );
  }

  static DateTime _when(Map<String, dynamic> json, String ms, String iso) {
    final millis = json[ms];
    if (millis is int) return DateTime.fromMillisecondsSinceEpoch(millis);
    return DateTime.parse(json[iso] as String);
  }
}

/// お気に入りエントリ（URLとメタデータのみ、画像データなし）。
class FavoriteEntry {
  final String imageId;
  final String name;
  final String uri;
  final String sourceKey; // e.g. "pixiv:default", "smb:1700000000000"
  final String? thumbnailUrl;
  final Map<String, dynamic> sourceInfo;
  final DateTime addedAt;

  const FavoriteEntry({
    required this.imageId,
    required this.name,
    required this.uri,
    this.sourceKey = 'pixiv:default',
    this.thumbnailUrl,
    required this.sourceInfo,
    required this.addedAt,
  });

  /// The same entry with a thumbnail URL that has replaced the stored one.
  /// [sourceInfo] carries its own copy (it is the metadata the item was starred
  /// with), so both are moved together or the stale one resurfaces the next
  /// time the entry is turned back into an ImageSource.
  FavoriteEntry withThumbnailUrl(String url) => FavoriteEntry(
        imageId: imageId,
        name: name,
        uri: uri,
        sourceKey: sourceKey,
        thumbnailUrl: url,
        sourceInfo: {...sourceInfo, 'thumbnailUrl': url},
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'uri': uri,
        'sourceKey': sourceKey,
        'thumbnailUrl': thumbnailUrl,
        'sourceInfo': sourceInfo,
        'addedAt': addedAt.toIso8601String(),
      };

  factory FavoriteEntry.fromJson(String imageId, Map<String, dynamic> json) {
    return FavoriteEntry(
      imageId: imageId,
      name: json['name'] as String? ?? '',
      uri: json['uri'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? 'pixiv:default',
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
