import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:exif/exif.dart';
import 'package:logging/logging.dart';

import '../../models/image_source.dart';
import '../../models/server_config.dart';
import '../../utils/natural_sort.dart';
import '../../widgets/thumbnail_result.dart';
import '../cache/cache_manager.dart';
import 'image_source_provider.dart';

final _log = Logger('SMB');

/// SMB2経由の画像取得。
class SmbSource extends ImageSourceProvider {
  final ServerConfig config;
  final String password;
  final CacheManager? cacheManager;
  Smb2Client? _client;
  Smb2Tree? _tree;

  static const _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  };

  static const _zipExtensions = {'.zip'};

  Future<Smb2Tree>? _connectFuture;

  SmbSource({required this.config, required this.password, this.cacheManager});

  Future<Smb2Tree> _connect() {
    return _connectFuture ??= _doConnect();
  }

  Future<Smb2Tree> _doConnect() async {
    final share = config.shareName ?? '';
    _log.info('Connecting to ${config.host}/$share...');
    try {
      _client = await Smb2Client.connect(
        host: config.host,
        port: config.port,
        username: config.username ?? '',
        password: password,
      );
      _log.info('Connected: dialect=${Smb2Dialect.describe(_client!.dialectRevision)}, '
          'maxRead=${_client!.maxReadSize}');
      _tree = await _client!.connectTree(share);
      return _tree!;
    } catch (e, st) {
      _log.severe('Connection error', e, st);
      // Clean up partial connection to avoid leaking _client
      if (_client != null) {
        try {
          await _client!.disconnect();
        } catch (disconnectErr, disconnectSt) {
          _log.warning('disconnect error during cleanup', disconnectErr, disconnectSt);
        }
        _client = null;
      }
      _connectFuture = null; // Allow retry on failure
      rethrow;
    }
  }

  @override
  Future<List<ImageSource>> listImages({String? path}) async {
    final tree = await _connect();
    final dirPath = path ?? config.basePath ?? '/';

    _log.info('Listing: $dirPath');
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
      } else if (_zipExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: 'smb:${config.id}:${file.path}',
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: smbSourceKey,
          metadata: {
            'isDirectory': false,
            'isZip': true,
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

  @override
  Future<List<ImageSource>> resolvePages(ImageSource source) async {
    if (source.metadata?['isZip'] != true) return [source];

    final zipPath = source.uri;
    final smbSourceKey = 'smb:${config.id}';
    _log.info('resolvePages: extracting ZIP $zipPath');

    // Download entire ZIP
    final zipData = await fetchFullImage(source);
    _log.info('resolvePages: ZIP downloaded (${(zipData.length / 1024).toStringAsFixed(0)} KB)');

    // Decode ZIP in memory
    final archive = ZipDecoder().decodeBytes(zipData);

    // Filter image files and sort naturally
    final imageFiles = archive.files
        .where((f) => !f.isFile ? false : _isImageName(f.name))
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));

    _log.info('resolvePages: ${imageFiles.length} images in ZIP');

    final pages = <ImageSource>[];
    for (var i = 0; i < imageFiles.length; i++) {
      final file = imageFiles[i];
      final pageId = 'smb:${config.id}:$zipPath#${file.name}';
      final cacheKey = 'full:$pageId';

      // Store each page in L2 cache
      if (cacheManager != null) {
        final data = file.content as Uint8List;
        await cacheManager!.l2.put(cacheKey, data);
      }

      final baseName = file.name.contains('/')
          ? file.name.split('/').last
          : file.name;

      pages.add(ImageSource(
        id: pageId,
        name: '${source.name} (${i + 1}/${imageFiles.length}) $baseName',
        uri: '$zipPath#${file.name}',
        type: ImageSourceType.smb,
        sourceKey: smbSourceKey,
        metadata: {
          'isDirectory': false,
          'isZipEntry': true,
          'zipPath': zipPath,
          'entryName': file.name,
          'path': source.metadata?['path'],
        },
      ));
    }

    return pages;
  }

  static bool _isImageName(String name) {
    final lower = name.toLowerCase();
    // Skip macOS resource fork files
    if (lower.contains('__macosx') || lower.contains('/.')) return false;
    return _imageExtensions.any((ext) => lower.endsWith(ext));
  }

  /// サムネイル取得。戻り値の `isFullImage` でフォールバックしたか判定。
  /// 並行呼び出しに安全（インスタンス変数を使わない）。
  Future<({Uint8List data, bool isFullImage})> fetchThumbnailWithInfo(ImageSource source) async {
    // ZIP files: thumbnail not supported at listing time
    if (source.metadata?['isZip'] == true) {
      throw ThumbnailNotSupportedException('ZIP: ${source.name}');
    }

    final name = source.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
      try {
        final header = await _readPartial(source.uri, 65536);
        final exifData = await readExifFromBytes(header);
        final thumbnail = exifData['JPEGThumbnail'];
        if (thumbnail != null) {
          final bytes = thumbnail.values.toList();
          if (bytes.isNotEmpty) {
            _log.info('EXIF thumbnail found for ${source.name} (${bytes.length} bytes)');
            return (data: Uint8List.fromList(bytes.cast<int>()), isFullImage: false);
          }
        }
        _log.info('Fallback to full image: no EXIF thumbnail (${source.name})');
      } catch (e, st) {
        _log.warning('Fallback to full image: EXIF parse error (${source.name})', e, st);
      }
    } else {
      _log.info('Fallback to full image: not JPEG (${source.name})');
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
    // ZIP entries are already cached by resolvePages
    if (source.metadata?['isZipEntry'] == true && cacheManager != null) {
      final cacheKey = 'full:${source.id}';
      final cached = await cacheManager!.get(cacheKey);
      if (cached != null) {
        _log.info('ZIP entry from cache: ${source.name} (${cached.data.length} bytes)');
        return Uint8List.fromList(cached.data);
      }
      _log.warning('ZIP entry not in cache: ${source.name}, key=$cacheKey');
    }

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
      _log.info('Downloaded ${source.name}: ${(received / 1024).toStringAsFixed(0)} KB in ${seconds.toStringAsFixed(2)}s ($speed KB/s)');

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
