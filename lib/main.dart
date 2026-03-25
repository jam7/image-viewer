import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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

  // dart_smb2: Smb2Client (connect/auth) at INFO — infrequent, useful for tracing.
  // Smb2Multiplexer/Tree/FileReader at WARNING — high volume I/O logs suppressed.
  Logger('Smb2Multiplexer').level = Level.WARNING;
  Logger('Smb2Tree').level = Level.WARNING;
  Logger('Smb2FileReader').level = Level.WARNING;

  // pdfrx: set cache directory for PDFium engine
  final cacheDir = await getTemporaryDirectory();
  Pdfrx.getCacheDirectory = () => cacheDir.path;

  runApp(const ImageViewerApp());
}
