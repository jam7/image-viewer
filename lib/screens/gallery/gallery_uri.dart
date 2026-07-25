/// Addresses of the places a gallery can show (ADR 007 決定 4 / ADR 008).
///
/// A URI says *where* a session looks. It is not a tab identity — the same URI
/// may be open in several tabs — and it is what a link or a duplicated tab
/// carries.
///
/// One shape for every scheme: **`<scheme>://<instanceId>/<path>`**. The
/// authority names which instance of the source, and the path names the place
/// within it.
///
/// ```
/// smb://<configId>/<dir>/<subdir>     a directory on one registered server
/// pixiv://default/top                 the Pixiv top page
/// pixiv://default/bookmarks           bookmarks
/// pixiv://default/user/<id>           one author's works
/// pixiv://default/search?word=..&s_mode=..&order=..
/// fav://default/                      everything starred, across sources
/// ```
///
/// SMB has many servers, so its instance id varies; Pixiv has one, so its
/// instance id is always `default`. Spelling it out rather than dropping the
/// authority is what keeps the two the same shape — and it makes [sourceKeyOf]
/// a single rule, matching the keys the registry already uses (`smb:<configId>`,
/// `pixiv:default`).
///
/// SMB paths are backslash-separated and may hold any character a filename can
/// (spaces, `#`, `%`, non-ASCII). They are carried as URI path *segments*, so
/// the separator becomes `/` and everything else is percent-encoded. That is
/// lossless because SMB, like Windows, cannot have `/` inside a name — and it
/// only works via [Uri.pathSegments]; `Uri.path` hands back the still-encoded
/// string. A leading separator is dropped, matching what dart_smb2's
/// `_normalizePath` does to the path anyway.
library;

const smbUriScheme = 'smb';
const pixivUriScheme = 'pixiv';
const favUriScheme = 'fav';

/// The instance id for sources that only ever have one — Pixiv's account,
/// the local favorites. They need no per-server id the way SMB does, but the
/// slot is still filled so every scheme reads the same.
const pixivInstance = 'default';

/// Address of the SMB directory [path] on the server registered as [configId].
Uri smbGalleryUri(String configId, String path) => Uri(
      scheme: smbUriScheme,
      host: configId,
      pathSegments: _smbSegments(path),
    );

/// Address of the starred works from every source.
Uri favGalleryUri() => Uri(scheme: favUriScheme, host: pixivInstance);

/// Address of the Pixiv page at the internal [path] (`/top`, `/user/123`,
/// `/search?word=...`).
Uri pixivGalleryUri(String path) =>
    Uri.parse('$pixivUriScheme://$pixivInstance$path');

/// The registry key for the source [uri] lives on: scheme plus instance, which
/// is exactly the `type:id` form `SourceRegistry.resolve` takes.
String sourceKeyOf(Uri uri) => '${uri.scheme}:${uri.host}';

/// The SMB directory [uri] points at, in the backslash-separated form the
/// provider expects. `/` for the share root.
String smbPathOf(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty);
  return segments.isEmpty ? '/' : segments.join(r'\');
}

/// The Pixiv internal path [uri] points at, query included.
String pixivPathOf(Uri uri) =>
    uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

List<String> _smbSegments(String path) =>
    path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
