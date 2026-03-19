import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:exif/exif.dart';

import '../../models/image_source.dart';
import '../../models/server_config.dart';
import '../../utils/natural_sort.dart';
import 'image_source_provider.dart';

/// SMB2経由の画像取得。
class SmbSource extends ImageSourceProvider {
  final ServerConfig config;
  final String password;
  Smb2Client? _client;
  Smb2Tree? _tree;

  static const _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  };

  SmbSource({required this.config, required this.password});

  Future<Smb2Tree> _connect() async {
    if (_tree != null) return _tree!;
    final share = config.shareName ?? '';
    print('[SMB] Connecting to ${config.host}/$share...');
    try {
      _client = await Smb2Client.connect(
        host: config.host,
        port: config.port,
        username: config.username ?? '',
        password: password,
      );
      print('[SMB] Connected: dialect=${Smb2Dialect.describe(_client!.dialectRevision)}, '
          'maxRead=${_client!.maxReadSize}');
      _tree = await _client!.connectTree(share);
      return _tree!;
    } catch (e, st) {
      print('[SMB] Connection error: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    final tree = await _connect();
    final dirPath = path ?? config.basePath ?? '/';

    print('[SMB] Listing: $dirPath');
    final files = await tree.listDirectory(dirPath);

    final sources = <ImageSource>[];
    for (final file in files) {
      final name = file.name;
      final ext = name.contains('.')
          ? '.${name.split('.').last.toLowerCase()}'
          : '';

      final smbSourceKey = 'smb:${config.id}';
      if (file.isDirectory) {
        sources.add(ImageSource(
          id: 'smb:${config.id}:${file.path}',
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: smbSourceKey,
          metadata: {
            'isDirectory': true,
            'path': file.path,
          },
        ));
      } else if (_imageExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: 'smb:${config.id}:${file.path}',
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: smbSourceKey,
          metadata: {
            'isDirectory': false,
            'path': file.path,
          },
        ));
      }
    }

    // ディレクトリを先、ファイルは自然順ソート
    sources.sort((a, b) {
      final aDir = a.metadata?['isDirectory'] == true;
      final bDir = b.metadata?['isDirectory'] == true;
      if (aDir != bDir) return aDir ? -1 : 1;
      return naturalCompare(a.name, b.name);
    });

    return sources;
  }

  /// サムネイル取得。戻り値の `isFullImage` でフォールバックしたか判定。
  /// 並行呼び出しに安全（インスタンス変数を使わない）。
  Future<({Uint8List data, bool isFullImage})> fetchThumbnailWithInfo(ImageSource source) async {
    final name = source.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
      try {
        final header = await _readPartial(source.uri, 65536);
        final exifData = await readExifFromBytes(header);
        final thumbnail = exifData['JPEGThumbnail'];
        if (thumbnail != null) {
          final bytes = thumbnail.values.toList();
          if (bytes.isNotEmpty) {
            print('[SMB] EXIF thumbnail found for ${source.name} (${bytes.length} bytes)');
            return (data: Uint8List.fromList(bytes.cast<int>()), isFullImage: false);
          }
        }
        print('[SMB] Fallback to full image: no EXIF thumbnail (${source.name})');
      } catch (e, st) {
        print('[SMB] Fallback to full image: EXIF parse error (${source.name}): $e\n$st');
      }
    } else {
      print('[SMB] Fallback to full image: not JPEG (${source.name})');
    }
    return (data: await fetchFullImage(source), isFullImage: true);
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    final result = await fetchThumbnailWithInfo(source);
    return result.data;
  }

  /// ファイルの先頭 [length] バイトだけ読み込む。
  Future<Uint8List> _readPartial(String path, int length) async {
    final tree = await _connect();
    final reader = await tree.openRead(path);
    try {
      return await reader.readRange(0, length);
    } finally {
      await reader.close();
    }
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final tree = await _connect();
    final reader = await tree.openRead(source.uri);
    try {
      final chunks = <Uint8List>[];
      int received = 0;
      await for (final chunk in reader.readStream()) {
        chunks.add(chunk);
        received += chunk.length;
        onProgress?.call(received, reader.fileSize);
      }

      stopwatch.stop();
      final seconds = stopwatch.elapsedMilliseconds / 1000;
      final speed = seconds > 0 ? (received / 1024 / seconds).toStringAsFixed(0) : '?';
      print('[SMB] Downloaded ${source.name}: ${(received / 1024).toStringAsFixed(0)} KB in ${seconds.toStringAsFixed(2)}s ($speed KB/s)');

      final result = Uint8List(received);
      int offset = 0;
      for (final chunk in chunks) {
        result.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      return result;
    } finally {
      await reader.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_client != null) {
      await _client!.disconnect();
      _client = null;
      _tree = null;
    }
  }
}
