/// Addresses of the places a gallery can show (ADR 007 決定 4 / ADR 008).
///
/// A URI says *where* a session looks. It is not a tab identity — the same URI
/// may be open in several tabs — and it is what a link or a duplicated tab
/// carries.
///
/// ```
/// smb://<configId>/<dir>/<subdir>     an SMB directory
/// pixiv:/top                          the Pixiv top page
/// pixiv:/bookmarks                    bookmarks
/// pixiv:/favorites                    locally starred works
/// pixiv:/user/<id>                    one author's works
/// pixiv:/search?word=..&s_mode=..&order=..
/// ```
///
/// SMB paths are backslash-separated and may hold any character a filename can
/// (spaces, `#`, `%`, non-ASCII). They are carried as URI path *segments*, so
/// the separator becomes `/` and everything else is percent-encoded. That is
/// lossless because SMB, like Windows, cannot have `/` inside a name — and it
/// only works via [Uri.pathSegments]; `Uri.path` hands back the still-encoded
/// string. A leading separator is dropped, matching what dart_smb2's
/// `_normalizePath` does to the path anyway.
///
/// Pixiv keeps its internal path (`/user/123`, `/search?...`) in the URI's own
/// path and query, so `pixiv:` has no authority and reads `pixiv:/top` rather
/// than the `pixiv://top` sketched in ADR 007. Same information, one less
/// reassembly step.
library;

const smbUriScheme = 'smb';
const pixivUriScheme = 'pixiv';

/// Address of the SMB directory [path] on the server registered as [configId].
Uri smbGalleryUri(String configId, String path) => Uri(
      scheme: smbUriScheme,
      host: configId,
      pathSegments: _smbSegments(path),
    );

/// Address of the Pixiv page at the internal [path] (`/top`, `/user/123`,
/// `/search?word=...`).
Uri pixivGalleryUri(String path) => Uri.parse('$pixivUriScheme:$path');

/// The SMB server config id [uri] points at, or null if it is not an SMB URI.
String? smbConfigIdOf(Uri uri) =>
    uri.scheme == smbUriScheme ? uri.host : null;

/// The SMB directory [uri] points at, in the backslash-separated form the
/// provider expects. `/` for the share root.
String smbPathOf(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty);
  return segments.isEmpty ? '/' : segments.join(r'\');
}

/// The Pixiv internal path [uri] points at, query included.
String pixivPathOf(Uri uri) =>
    uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

/// Whether [uri] is the locally starred works page, which is served from a
/// finite local list rather than paged from the source.
bool isPixivFavoritesUri(Uri uri) =>
    uri.scheme == pixivUriScheme && uri.path == '/favorites';

List<String> _smbSegments(String path) =>
    path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
