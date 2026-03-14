/// Pixiv作品モデル。Web Ajax APIのレスポンスに対応。
class PixivArtwork {
  final int id;
  final String title;
  final String caption;
  final PixivUser user;
  final List<String> tags;
  final PixivImageUrls imageUrls;
  final List<PixivPage> pages;
  final int pageCount;
  final int width;
  final int height;
  final bool isBookmarked;
  final int totalBookmarks;
  final int totalView;

  const PixivArtwork({
    required this.id,
    required this.title,
    required this.caption,
    required this.user,
    required this.tags,
    required this.imageUrls,
    required this.pages,
    required this.pageCount,
    required this.width,
    required this.height,
    required this.isBookmarked,
    required this.totalBookmarks,
    required this.totalView,
  });

  /// /ajax/illust/{id} のレスポンスbodyからパース。
  factory PixivArtwork.fromWebJson(Map<String, dynamic> json) {
    final tagsBody = json['tags'] as Map<String, dynamic>?;
    final tagList = (tagsBody?['tags'] as List<dynamic>?)
            ?.map((t) => (t as Map<String, dynamic>)['tag'] as String)
            .toList() ??
        [];

    final urls = json['urls'] as Map<String, dynamic>? ?? {};

    return PixivArtwork(
      id: _parseInt(json['illustId']),
      title: json['illustTitle'] as String? ?? '',
      caption: json['illustComment'] as String? ?? '',
      user: PixivUser(
        id: _parseInt(json['userId']),
        name: json['userName'] as String? ?? '',
      ),
      tags: tagList,
      imageUrls: PixivImageUrls(
        thumb: urls['thumb'] as String? ?? urls['small'] as String? ?? '',
        small: urls['small'] as String? ?? '',
        regular: urls['regular'] as String? ?? '',
        original: urls['original'] as String?,
      ),
      pages: [],
      pageCount: json['pageCount'] as int? ?? 1,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      isBookmarked: json['bookmarkData'] != null,
      totalBookmarks: json['bookmarkCount'] as int? ?? 0,
      totalView: json['viewCount'] as int? ?? 0,
    );
  }

  /// サムネイル一覧（/ajax/top/illust, 検索結果等）からパース。
  factory PixivArtwork.fromThumbnailJson(Map<String, dynamic> json) {
    final tagList = (json['tags'] as List<dynamic>?)
            ?.map((t) => t as String)
            .toList() ??
        [];

    return PixivArtwork(
      id: _parseInt(json['id']),
      title: json['title'] as String? ?? '',
      caption: json['description'] as String? ?? '',
      user: PixivUser(
        id: _parseInt(json['userId']),
        name: json['userName'] as String? ?? '',
      ),
      tags: tagList,
      imageUrls: PixivImageUrls(
        thumb: json['url'] as String? ?? '',
        small: json['url'] as String? ?? '',
        regular: json['url'] as String? ?? '',
        original: null,
      ),
      pages: [],
      pageCount: json['pageCount'] as int? ?? 1,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      isBookmarked: json['bookmarkData'] != null,
      totalBookmarks: json['bookmarkCount'] as int? ?? 0,
      totalView: json['viewCount'] as int? ?? 0,
    );
  }

  /// サムネイルURLを取得。
  String get thumbnailUrl => imageUrls.thumb;

  /// オリジナル画像URL（単ページ作品用）。
  String? get originalImageUrl => imageUrls.original;

  static int _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

class PixivUser {
  final int id;
  final String name;

  const PixivUser({
    required this.id,
    required this.name,
  });
}

class PixivImageUrls {
  final String thumb;
  final String small;
  final String regular;
  final String? original;

  const PixivImageUrls({
    required this.thumb,
    required this.small,
    required this.regular,
    this.original,
  });
}

/// 作品の各ページ情報。/ajax/illust/{id}/pages から取得。
class PixivPage {
  final String thumbUrl;
  final String smallUrl;
  final String regularUrl;
  final String originalUrl;
  final int width;
  final int height;

  const PixivPage({
    required this.thumbUrl,
    required this.smallUrl,
    required this.regularUrl,
    required this.originalUrl,
    required this.width,
    required this.height,
  });

  factory PixivPage.fromWebJson(Map<String, dynamic> json) {
    final urls = json['urls'] as Map<String, dynamic>? ?? {};
    return PixivPage(
      thumbUrl: urls['thumb_mini'] as String? ?? '',
      smallUrl: urls['small'] as String? ?? '',
      regularUrl: urls['regular'] as String? ?? '',
      originalUrl: urls['original'] as String? ?? '',
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
    );
  }
}

/// イラスト一覧 + ページネーション。
class PixivIllustList {
  final List<PixivArtwork> illusts;
  final int? nextOffset;

  const PixivIllustList({required this.illusts, this.nextOffset});

  bool get hasMore => nextOffset != null;
}
