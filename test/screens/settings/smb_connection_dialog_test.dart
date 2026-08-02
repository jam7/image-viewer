import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/screens/settings/smb_connection_dialog.dart';

/// The form the whole SMB side depends on: get a field wrong here and there
/// is no connection to debug later.
void main() {
  Future<void> pumpDialog(WidgetTester tester, {ServerConfig? existing}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SmbConnectionDialog(existing: existing),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the form has a line for each thing a connection needs',
      (tester) async {
    await pumpDialog(tester);

    expect(find.byType(TextFormField), findsNWidgets(7));
  });

  testWidgets('an existing connection comes back in the fields',
      (tester) async {
    await pumpDialog(
      tester,
      existing: const ServerConfig(
        id: '1700000000000',
        name: 'server',
        type: ImageSourceType.smb,
        host: 'server',
        port: 4455,
        shareName: 'share',
        basePath: 'books',
      ),
    );

    expect(find.text('server'), findsNWidgets(2)); // name and host
    expect(find.text('4455'), findsOneWidget);
    expect(find.text('share'), findsOneWidget);
    expect(find.text('books'), findsOneWidget);
  });

  testWidgets('saving without a host is refused, and says which line',
      (tester) async {
    // Only the host and the share are checked: everything else has a sensible
    // empty, and an anonymous share is a real thing.
    await pumpDialog(tester);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();

    expect(find.text('必須'), findsNWidgets(2));
  });
}
