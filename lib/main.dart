import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'app.dart';

void main() {
  // App-wide logging setup. Output to print for debug console.
  // dart_smb2 loggers (Smb2Client, Smb2Multiplexer etc.) are in the same
  // Logger tree and filtered by level below.
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String().substring(11, 23);
    print('$time [${record.loggerName}] ${record.level.name}: ${record.message}');
    if (record.error != null) {
      print('  Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('  ${record.stackTrace}');
    }
  });

  // dart_smb2: only show warnings and above (suppress info-level connection logs)
  Logger('Smb2Client').level = Level.WARNING;
  Logger('Smb2Multiplexer').level = Level.WARNING;
  Logger('Smb2Tree').level = Level.WARNING;
  Logger('Smb2FileReader').level = Level.WARNING;

  runApp(const ImageViewerApp());
}
