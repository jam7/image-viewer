import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/smb_identity.dart';

/// What an SMB item is called and what it claims to be. The listing and the
/// URI rules both build items through here, so this is where the agreement
/// between them is pinned rather than in either of the two callers.
void main() {
  ImageSource item(String path, {bool dir = false}) => smbItem(
        configId: '1700000000000',
        path: path,
        name: path.split(r'\').last,
        isDirectory: dir,
      );

  test('the kind comes from the name, one flag at most', () {
    expect(item(r'books\book.zip').metadata?['isZip'], isTrue);
    expect(item(r'books\book.pdf').metadata?['isPdf'], isTrue);
    expect(item(r'books\movie.mp4').metadata?['isVideo'], isTrue);
  });

  test('a picture claims nothing: it is what the rest of the app assumes', () {
    final picture = item(r'books\a.jpg');
    expect(picture.metadata, {'isDirectory': false, 'path': r'books\a.jpg'});
  });

  test('but only the share can say whether it is a folder', () {
    // A folder may be called anything, `test.jpg` included, and one so named
    // used to be opened in the viewer over what should have been its listing.
    final folder = item('test.jpg', dir: true);
    expect(folder.metadata?['isDirectory'], isTrue);
    expect(folder.metadata?.containsKey('isVideo'), isFalse);
  });

  test('and the item is named the way the id is', () {
    final picture = item(r'books\a.jpg');
    expect(picture.id, smbItemId('1700000000000', r'books\a.jpg'));
    expect(picture.sourceKey, smbSourceKey('1700000000000'));
    expect(picture.uri, r'books\a.jpg');
    expect(picture.name, 'a.jpg');
    expect(picture.type, ImageSourceType.smb);
  });
}
