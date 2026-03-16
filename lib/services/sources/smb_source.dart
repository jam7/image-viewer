import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:smb_connect/smb_connect.dart';

import '../../models/image_source.dart';
import '../../models/server_config.dart';
import 'image_source_provider.dart';

/// SMB2経由の画像取得。
class SmbSource implements ImageSourceProvider {
  final ServerConfig config;
  final String password;
  SmbConnect? _client;

  static const _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  };

  SmbSource({required this.config, required this.password});

  Future<SmbConnect> _connect() async {
    if (_client != null) return _client!;
    print('[SMB] Connecting to ${config.host}/${config.shareName}...');
    try {
      _client = await SmbConnect.connectAuth(
        host: config.host,
        domain: '',
        username: config.username ?? '',
        password: password,
      );
      print('[SMB] Connected');
      return _client!;
    } catch (e, st) {
      print('[SMB] Connection error: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    final client = await _connect();
    final share = config.shareName ?? '';
    final dirPath = path ?? config.basePath ?? '/';
    final fullPath = '/$share$dirPath';

    print('[SMB] Listing: $fullPath');
    final folder = await client.file(fullPath);
    final files = await client.listFiles(folder);

    final sources = <ImageSource>[];
    for (final file in files) {
      final name = file.path.split('/').last;
      if (name == '.' || name == '..') continue;

      final isDir = file.isDirectory();
      final ext = name.contains('.')
          ? '.${name.split('.').last.toLowerCase()}'
          : '';

      if (isDir) {
        sources.add(ImageSource(
          id: 'smb:${config.id}:${file.path}',
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          metadata: {
            'isDirectory': true,
            'path': file.path.replaceFirst('/$share', ''),
          },
        ));
      } else if (_imageExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: 'smb:${config.id}:${file.path}',
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          metadata: {
            'isDirectory': false,
            'path': file.path,
          },
        ));
      }
    }

    // ディレクトリを先、ファイルは名前順
    sources.sort((a, b) {
      final aDir = a.metadata?['isDirectory'] == true;
      final bDir = b.metadata?['isDirectory'] == true;
      if (aDir != bDir) return aDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return sources;
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    // JPEG の EXIF サムネイルを抽出。なければフル画像にフォールバック。
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
            return Uint8List.fromList(bytes.cast<int>());
          }
        }
        print('[SMB] Fallback to full image: no EXIF thumbnail (${source.name})');
      } catch (e) {
        print('[SMB] Fallback to full image: EXIF parse error (${source.name}): $e');
      }
    } else {
      print('[SMB] Fallback to full image: not JPEG (${source.name})');
    }
    return fetchFullImage(source);
  }

  /// ファイルの先頭 [length] バイトだけ読み込む。
  Future<Uint8List> _readPartial(String path, int length) async {
    final client = await _connect();
    final file = await client.file(path);
    final stream = await client.openRead(file, 0, length);

    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
      if (chunks.length >= length) break;
    }

    return Uint8List.fromList(chunks);
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = await _connect();
    final file = await client.file(source.uri);
    final stream = await client.openRead(file);

    final chunks = <int>[];
    int received = 0;
    await for (final chunk in stream) {
      chunks.addAll(chunk);
      received += chunk.length as int;
      onProgress?.call(received, -1);
    }

    return Uint8List.fromList(chunks);
  }

  @override
  Future<void> dispose() async {
    await _client?.close();
    _client = null;
  }
}
