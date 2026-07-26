/// What a file name says about what is inside it.
///
/// Shared because two very different things need the same answer: a source
/// deciding how to list a file, and the URI rules deciding whether an address
/// names something to look at (ADR 010). Guessing differently in the two
/// places is how a folder called `vol.2` becomes a file.
library;

const imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};
const zipExtensions = {'.zip'};
const pdfExtensions = {'.pdf'};
const videoExtensions = {
  '.mp4', '.mkv', '.avi', '.webm', '.flv',
  '.mov', '.wmv', '.mpg', '.mpeg', '.m4v', '.ts',
};

/// Everything the viewer or the player can open.
const viewableExtensions = {
  ...imageExtensions,
  ...zipExtensions,
  ...pdfExtensions,
  ...videoExtensions,
};

/// The extension of [name], lowercased and with its dot — empty when it has
/// none. A trailing dot, or a name that is only a dot, has no extension.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot).toLowerCase();
}
