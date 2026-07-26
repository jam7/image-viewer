/// How an SMB file is named, in one place.
///
/// Two very different things build these strings and they have to agree
/// exactly: the source, listing a share, and the URI rules, working out which
/// item an address points at (ADR 010). When the viewer looks for itself in
/// the list it was opened from, it does so by id — so the day the two spellings
/// drift, moving between pictures stops working and says nothing about why.
library;

/// The registry key for the server registered as [configId]: `smb:<configId>`.
///
/// The same `type:instance` shape every source uses, and what
/// `sourceKeyOf(uri)` produces for an `smb://` address.
String smbSourceKey(String configId) => 'smb:$configId';

/// The id of the file at [path] on that server. [path] is the
/// backslash-separated form the share itself uses.
///
/// A page inside a container passes its own suffix — `book.zip#cover.jpg` —
/// so that a page is identified by where it is as well as what it is in.
String smbItemId(String configId, String path) =>
    '${smbSourceKey(configId)}:$path';
