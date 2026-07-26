import 'gallery_uri.dart';

/// How each source writes a place down, and reads one back out for a human.
///
/// [gallery_uri.dart] fixes the *shape* every address shares
/// (`<scheme>://<instanceId>/<path>`); what goes in the path and the query is
/// each source's own business, and so is what that means in words. Pixiv has
/// tags and match modes, SMB has directories, and a search means something
/// different in each. Those rules live here, one per scheme.
///
/// Everything in this file is a pure function of the URI. That is the point,
/// not an accident: a tab restored from disk has to be able to say where it is
/// **before** it can connect (ADR 009 の永続化), and a source that is offline
/// still has a name. Anything that needs a lookup — an author's name, a
/// server's nickname — belongs on `GallerySession.title`, which wins over
/// [describe] wherever both exist (see [placeTitle]).
abstract class GalleryUriDialect {
  const GalleryUriDialect();

  /// [uri] as something to show a reader. Says where the tab is without
  /// abbreviating — the tab chip is the short form, and it shortens
  /// differently because it only has to tell two tabs apart.
  String describe(Uri uri);

  /// What the address field invites when this source can be searched, e.g.
  /// 'タグ検索'. Null means it cannot, and [search] then returns null too.
  String? get searchHint => null;

  /// Where [query] leads, for a reader standing on [from]. Null if this source
  /// has no search.
  ///
  /// [from] is passed because what a search means depends on where it is
  /// issued: Pixiv carries the options of the search being refined, and SMB
  /// will scope to the directory being looked at. Callers hand over the
  /// current place and let the source decide what to do with it.
  Uri? search(Uri from, String query) => null;
}

const _dialects = <String, GalleryUriDialect>{
  homeUriScheme: _HomeDialect(),
  favUriScheme: _FavoritesDialect(),
  pixivUriScheme: _PixivDialect(),
  smbUriScheme: _SmbDialect(),
};

/// [input] read as a place, or null if it is not one — an unknown scheme, a
/// URI with no instance, or plain text.
///
/// Null is not an error: it is the address field's signal to search instead.
/// Typing `smb://` and hitting enter halfway through searches rather than
/// complaining, which is the safe way round (design.md 節 7).
Uri? parsePlace(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !_dialects.containsKey(uri.scheme)) return null;
  return uri.host.isEmpty ? null : uri;
}

/// What [uri] alone can say it is. Falls back to the URI itself for a scheme
/// with no dialect, which is honest: it is all we know.
String describePlace(Uri uri) => _dialects[uri.scheme]?.describe(uri) ?? '$uri';

/// See [GalleryUriDialect.search].
Uri? searchFrom(Uri from, String query) =>
    _dialects[from.scheme]?.search(from, query);

/// See [GalleryUriDialect.searchHint].
String? searchHintFor(Uri uri) => _dialects[uri.scheme]?.searchHint;

/// What to call the place at [uri], given the [known] name a session picked up
/// on arriving there. The name wins when there is one: only the source can
/// know an author is called テスト作者, while the URI knows the rest.
String placeTitle(Uri uri, String known) =>
    known.isEmpty ? describePlace(uri) : known;

class _HomeDialect extends GalleryUriDialect {
  const _HomeDialect();

  @override
  String describe(Uri uri) => 'ホーム';
}

class _FavoritesDialect extends GalleryUriDialect {
  const _FavoritesDialect();

  @override
  String describe(Uri uri) => 'お気に入り';
}

class _PixivDialect extends GalleryUriDialect {
  const _PixivDialect();

  static final _user = RegExp(r'^/user/(\d+)$');

  @override
  String describe(Uri uri) {
    if (uri.path.startsWith('/search')) return _describeSearch(uri);
    final user = _user.firstMatch(uri.path);
    if (user != null) return '${user.group(1)} の作品';
    if (uri.path == '/bookmarks') return 'ブックマーク一覧';
    return 'Pixiv';
  }

  /// The word, plus only the options that are *not* the default. A search that
  /// asked for something unusual should say so — losing track of why a list
  /// looks the way it does is this UI's typical accident — while the ordinary
  /// case stays short enough to read in a narrow field.
  String _describeSearch(Uri uri) {
    final q = uri.queryParameters;
    final notes = [
      if (q['s_mode'] == 's_tag') '部分',
      if (q['order'] == 'date') '古い順',
    ];
    final word = q['word'] ?? '';
    return notes.isEmpty ? word : '$word (${notes.join('・')})';
  }

  @override
  String? get searchHint => 'タグ検索 または URI';

  /// Only a search page carries these, so refining a query keeps 完全一致 /
  /// 並び順 while searching from anywhere else starts from the defaults.
  @override
  Uri? search(Uri from, String query) => pixivSearchUri(
        query,
        mode: from.queryParameters['s_mode'],
        order: from.queryParameters['order'],
      );
}

class _SmbDialect extends GalleryUriDialect {
  const _SmbDialect();

  /// The whole path, not its tail. The server it is on is missing because the
  /// URI carries a config id rather than the nickname, and resolving that
  /// needs the store — so it stays on the session title.
  @override
  String describe(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty);
    return segments.isEmpty ? '/' : segments.join('/');
  }
}
