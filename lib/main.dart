import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
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

  // pdfrx 2.4+: explicit initialization sets the PDFium cache directory
  // (temporary directory via path_provider) and loads the engine.
  await pdfrxFlutterInitialize();

  _reportSlowFrames();

  runApp(const ImageViewerApp());
}

/// Say which half of a slow frame was slow.
///
/// Build is this app's own code — laying out the grid, running our callbacks.
/// Raster is the engine turning that into pixels, where decoding a thumbnail
/// and handing it to the GPU lands. A stutter looks the same from the outside
/// either way, and every fix so far has assumed the first.
///
/// Only frames past twice the budget are reported: a 60Hz frame is 16ms, and
/// a line per frame would itself be the problem.
void _reportSlowFrames() {
  final log = Logger('Frames');
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final frame in timings) {
      final build = frame.buildDuration.inMilliseconds;
      final raster = frame.rasterDuration.inMilliseconds;
      if (build + raster < 32) continue;
      log.info('frame: build ${build}ms + raster ${raster}ms');
    }
  });
}
