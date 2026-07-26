import '../../models/image_source.dart';
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

/// Somewhere this source offers to go, for a menu: what to call it and where
/// it is.
typedef PlaceLink = ({String label, Uri uri});

/// A switch that rides along with a search: how it reads right now, and the
/// address it becomes when pressed. The caller shows [label] and, on a tap,
/// carries on from [next] — it never has to know what the switch is called in
/// the source's own query.
typedef SearchOption = ({String label, Uri next});

abstract class GalleryUriDialect {
  const GalleryUriDialect();

  /// [uri] as something to show a reader. Says where the tab is without
  /// abbreviating — the tab chip is the short form, and it shortens
  /// differently because it only has to tell two tabs apart.
  String describe(Uri uri);

  /// The name this place turns out to have once its contents arrive, or null
  /// if [items] say nothing the URI did not already.
  ///
  /// The counterpart to [describe]: an author page is `12345 の作品` until the
  /// first page comes back, and the author's name is in every item of it. Only
  /// the source knows where in its own data that name is, which is why this is
  /// here and not in the session.
  String? titleFrom(Uri uri, List<ImageSource> items) => null;

  /// The item [uri] names, built without looking anything up — or null when
  /// the address names a list rather than one of its members.
  ///
  /// This is what makes a viewer a place (ADR 010). Two things need it: the
  /// host, to tell a work from a folder without inspecting paths itself, and
  /// the viewer, which may be opened on an address pasted from somewhere else
  /// and then has nowhere to get the item from. What comes back carries only
  /// what the address said; everything else is fetched as usual.
  ///
  /// The id must be the same string the source's own listing produces, since
  /// that is how the viewer finds itself in the list it was opened from.
  ImageSource? itemOf(Uri uri) => null;

  /// The address of [item], the other way round from [itemOf]. Null for an
  /// item that is not somewhere the app can be (an SMB directory is a list,
  /// and has its own address as such).
  Uri? placeOf(ImageSource item) => null;

  /// Whether [uri] names somewhere this source can actually be.
  ///
  /// A URI can be perfectly well-formed and still be nowhere:
  /// `pixiv://default/usr/12345` parses, and the provider would then try to
  /// read `usr/12345` as a page and fail. Saying so here keeps that answer
  /// where the rest of the source's URI rules are, rather than making every
  /// provider defend itself against addresses that were never real.
  ///
  /// Default is yes — a source whose places are its own contents (SMB
  /// directories) cannot say more than the syntax already did.
  bool knows(Uri uri) => true;

  /// The source's own sections — the places it offers to jump to from
  /// anywhere in it. Empty for a source that is a single place.
  List<PlaceLink> get sections => const [];

  /// Whether an item from this source is a work of several pages, so that
  /// "at least N pages" means anything. A fact about the source's data, not a
  /// preference: SMB lists files, and a file has no page count.
  bool get hasPageCounts => false;

  /// What tapping the address window should put in front of the reader, ready
  /// to be changed — and empty when there is nothing worth reopening.
  ///
  /// Empty is the usual answer. A place is normally reached by following
  /// something or pasting it, never by editing an address by hand, and the
  /// address is copyable from the menu for taking elsewhere. Showing it here
  /// would only be something to delete first — percent-encoded, at that.
  ///
  /// A source hands something back when the place is largely one piece of text
  /// the reader wrote themselves: a search word, which is exactly what they
  /// have come back to change.
  String editable(Uri uri) => '';

  /// What the address field invites when this source can be searched, e.g.
  /// 'タグ検索'. Null means it cannot, and [search] then returns null too.
  String? get searchHint => null;

  /// The switches to offer beside a search being typed at [from]. Empty for a
  /// source whose search has no options — and for one with no search at all.
  List<SearchOption> searchOptions(Uri from) => const [];

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
///
/// "Not a place" covers the shape as well as the syntax: see
/// [GalleryUriDialect.knows]. A misspelt page is searched for rather than
/// navigated to, which is the same safe direction.
Uri? parsePlace(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final dialect = _dialects[uri.scheme];
  if (dialect == null || !dialect.knows(uri)) return null;
  return uri;
}

/// What [uri] alone can say it is. Falls back to the URI itself for a scheme
/// with no dialect, which is honest: it is all we know.
String describePlace(Uri uri) => _dialects[uri.scheme]?.describe(uri) ?? '$uri';

/// See [GalleryUriDialect.search].
Uri? searchFrom(Uri from, String query) =>
    _dialects[from.scheme]?.search(from, query);

/// See [GalleryUriDialect.searchHint].
String? searchHintFor(Uri uri) => _dialects[uri.scheme]?.searchHint;

/// See [GalleryUriDialect.editable].
String editableOf(Uri uri) => _dialects[uri.scheme]?.editable(uri) ?? '';

/// See [GalleryUriDialect.itemOf].
ImageSource? itemOf(Uri uri) => _dialects[uri.scheme]?.itemOf(uri);

/// See [GalleryUriDialect.placeOf]. The source is read off the item, which
/// carries the same `type:instance` key the dialects are registered under.
Uri? placeOf(ImageSource item) =>
    _dialects[item.sourceKey?.split(':').first]?.placeOf(item);

/// See [GalleryUriDialect.sections].
List<PlaceLink> sectionsOf(Uri uri) =>
    _dialects[uri.scheme]?.sections ?? const [];

/// See [GalleryUriDialect.hasPageCounts].
bool hasPageCounts(Uri uri) => _dialects[uri.scheme]?.hasPageCounts ?? false;

/// See [GalleryUriDialect.searchOptions].
List<SearchOption> searchOptionsFor(Uri uri) =>
    _dialects[uri.scheme]?.searchOptions(uri) ?? const [];

/// See [GalleryUriDialect.titleFrom].
String? titleFromItems(Uri uri, List<ImageSource> items) =>
    _dialects[uri.scheme]?.titleFrom(uri, items);

/// What a Pixiv author page is called once the author is known. One wording,
/// used both by whoever already knew the name (a link, the viewer) and by the
/// page that had to wait for its first fetch to find out.
String pixivAuthorTitle(String name) => '$name の作品';

/// What to call the place at [uri], given the [known] name a session picked up
/// on arriving there. The name wins when there is one: only the source can
/// know an author is called テスト作者, while the URI knows the rest.
String placeTitle(Uri uri, String known) =>
    known.isEmpty ? describePlace(uri) : known;

/// A source that is exactly one place: it is somewhere or it is nothing, so
/// anything hanging off the root is a typo rather than a page.
abstract class _SinglePlaceDialect extends GalleryUriDialect {
  const _SinglePlaceDialect();

  @override
  bool knows(Uri uri) => uri.pathSegments.every((s) => s.isEmpty);
}

class _HomeDialect extends _SinglePlaceDialect {
  const _HomeDialect();

  @override
  String describe(Uri uri) => 'ホーム';
}

class _FavoritesDialect extends _SinglePlaceDialect {
  const _FavoritesDialect();

  @override
  String describe(Uri uri) => 'お気に入り';
}

class _PixivDialect extends GalleryUriDialect {
  const _PixivDialect();

  static final _user = RegExp(r'^/user/(\d+)$');
  static final _artwork = RegExp(r'^/artworks/(\d+)$');
  static final _page = RegExp(r'^/(top|bookmarks|user/\d+|artworks/\d+|search)$');

  /// The four pages this app knows how to be on.
  @override
  bool knows(Uri uri) {
    if (!_page.hasMatch(uri.path)) return false;
    // Only a search carries a query. The provider is handed path and query
    // together, so anywhere else it is read as part of the page's name and
    // breaks it — `/user/12345?s_mode=s_tag` asks Pixiv for author
    // "12345?s_mode=s_tag".
    if (uri.path != '/search') return !uri.hasQuery;
    // And a search with nothing to search for is half a URL, not a page.
    return (uri.queryParameters['word'] ?? '').isNotEmpty;
  }

  /// A work is named by the item, not the address: the address has only its
  /// number, and the title arrives with the work. Until then, the number.
  @override
  ImageSource? itemOf(Uri uri) {
    final id = _artwork.firstMatch(uri.path)?.group(1);
    if (id == null) return null;
    return ImageSource(
      id: id,
      name: '',
      uri: '',
      type: ImageSourceType.pixiv,
      sourceKey: sourceKeyOf(uri),
      metadata: {'illustId': int.parse(id)},
    );
  }

  @override
  Uri? placeOf(ImageSource item) => pixivArtworkUri(item.id);

  @override
  String describe(Uri uri) {
    final artwork = _artwork.firstMatch(uri.path);
    if (artwork != null) return '作品 ${artwork.group(1)}';
    if (uri.path.startsWith('/search')) return _describeSearch(uri);
    final user = _user.firstMatch(uri.path);
    if (user != null) return '${user.group(1)} の作品';
    if (uri.path == '/bookmarks') return 'ブックマーク一覧';
    return 'Pixiv';
  }

  /// Every work on an author's page carries the author, so the first page to
  /// arrive settles the name. Nothing else here is worth learning: a search
  /// already knows its own word, and the top page has no name to find.
  @override
  String? titleFrom(Uri uri, List<ImageSource> items) {
    if (!_user.hasMatch(uri.path) || items.isEmpty) return null;
    final author = items.first.metadata?['author'] as String?;
    return author == null || author.isEmpty ? null : pixivAuthorTitle(author);
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
  List<PlaceLink> get sections => [
        (label: 'トップ', uri: pixivGalleryUri('/top')),
        (label: 'ブックマーク', uri: pixivGalleryUri('/bookmarks')),
      ];

  @override
  bool get hasPageCounts => true;

  /// On a search, the word — that is what the reader wrote and what they come
  /// back to change. Refining `books` to `books series` should not mean
  /// picking it out of a query string.
  @override
  String editable(Uri uri) =>
      uri.path == '/search' ? uri.queryParameters['word'] ?? '' : '';

  @override
  String? get searchHint => 'タグ検索 または URI';

  /// Only a search page carries these, so refining a query keeps 完全一致 /
  /// 並び順 while searching from anywhere else starts from the defaults.
  @override
  Uri? search(Uri from, String query) =>
      _pastedPlace(query) ??
      pixivSearchUri(
        query,
        mode: from.queryParameters['s_mode'],
        order: from.queryParameters['order'],
      );

  /// A pixiv.net address pasted into the field, as the place it names.
  ///
  /// Only an author's page: a single work is not a place this app can be at,
  /// which is a gap the viewer will close when it becomes a tab of its own.
  Uri? _pastedPlace(String query) {
    final uri = Uri.tryParse(query);
    if (uri == null || !uri.host.endsWith('pixiv.net')) return null;
    final user = RegExp(r'/users/(\d+)').firstMatch(uri.path);
    return user == null ? null : pixivGalleryUri('/user/${user.group(1)}');
  }

  /// The switches, read off the address and handed back with the address they
  /// lead to. Pressing one rewrites where we are, because that is where the
  /// options live — they travel in the query, not beside it.
  @override
  List<SearchOption> searchOptions(Uri from) {
    final mode = from.queryParameters['s_mode'] ?? pixivDefaultSearchMode;
    final order = from.queryParameters['order'] ?? pixivDefaultSearchOrder;
    final full = mode == 's_tag_full';
    final newest = order == 'date_d';
    return [
      (
        label: full ? '完全' : '部分',
        next: _withQuery(from, 's_mode', full ? 's_tag' : 's_tag_full'),
      ),
      (
        label: newest ? '新着' : '古い順',
        next: _withQuery(from, 'order', newest ? 'date' : 'date_d'),
      ),
    ];
  }

  static Uri _withQuery(Uri uri, String key, String value) =>
      uri.replace(queryParameters: {...uri.queryParameters, key: value});
}

class _SmbDialect extends GalleryUriDialect {
  const _SmbDialect();

  /// A path ending in a name with an extension is a file, and a file is
  /// something to look at. A directory has no extension and is a list, which
  /// has its own address already.
  @override
  ImageSource? itemOf(Uri uri) {
    final path = smbPathOf(uri);
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (!name.contains('.')) return null;
    return ImageSource(
      id: 'smb:${uri.host}:$path',
      name: name,
      uri: path,
      type: ImageSourceType.smb,
      sourceKey: sourceKeyOf(uri),
      metadata: {'isDirectory': false, 'path': path},
    );
  }

  /// Null for anything that is not a single thing to look at: a directory is a
  /// list, and a video is not in the viewer yet (ADR 010 段階 6).
  @override
  Uri? placeOf(ImageSource item) {
    final meta = item.metadata;
    if (meta?['isDirectory'] == true || meta?['isVideo'] == true) return null;
    final path = meta?['path'] as String?;
    if (path == null) return null;
    return smbGalleryUri(item.sourceKey!.split(':').last, path);
  }

  /// The whole path, not its tail. The server it is on is missing because the
  /// URI carries a config id rather than the nickname, and resolving that
  /// needs the store — so it stays on the session title.
  @override
  String describe(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty);
    return segments.isEmpty ? '/' : segments.join('/');
  }
}
