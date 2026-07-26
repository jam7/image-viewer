/// How an SMB file is named and described, in one place.
///
/// Two very different things build these and they have to agree exactly: the
/// source, listing a share, and the URI rules, working out which item an
/// address points at (ADR 010). When the viewer looks for itself in the list
/// it was opened from, it does so by id — so the day the two spellings drift,
/// moving between pictures stops working and says nothing about why.
///
/// The id was the first thing they had to agree on. The rest of the item came
/// after: the URI rules had been building one of their own with no kind in it,
/// so a video reached by a pasted address was read as a picture — fetched
/// whole into memory, which is the one thing a video must not be.
library;

import 'image_source.dart';
import 'media_extensions.dart';

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

/// The item at [path] on that server, as everything downstream expects it.
///
/// [name] is what to call it — the last segment of [path] in a listing, and
/// whatever the address ends with otherwise. [isDirectory] is the one thing
/// the name cannot settle: a folder may be called `vol2.5`, or even `a.jpg`.
ImageSource smbItem({
  required String configId,
  required String path,
  required String name,
  required bool isDirectory,
}) {
  final kind = isDirectory ? null : _kindOf(extensionOf(name));
  return ImageSource(
    id: smbItemId(configId, path),
    name: name,
    uri: path,
    type: ImageSourceType.smb,
    sourceKey: smbSourceKey(configId),
    metadata: {
      'isDirectory': isDirectory,
      'path': path,
      ?kind: true,
    },
  );
}

/// The metadata flag that says how to open a file, or null for a picture —
/// which is the plain case and claims nothing.
String? _kindOf(String extension) {
  if (zipExtensions.contains(extension)) return 'isZip';
  if (pdfExtensions.contains(extension)) return 'isPdf';
  if (videoExtensions.contains(extension)) return 'isVideo';
  return null;
}
