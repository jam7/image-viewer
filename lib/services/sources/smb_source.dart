import 'dart:typed_data';

import 'package:archive_reader/archive_reader.dart';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:exif/exif.dart';
import 'package:logging/logging.dart';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../../models/image_source.dart';
import '../../models/server_config.dart';
import '../../utils/natural_sort.dart';
import '../../widgets/thumbnail_result.dart';
import '../cache/cache_manager.dart';
import 'image_source_provider.dart';

final _log = Logger('SMB');

/// SMB2経由の画像取得。
class SmbSource extends ImageSourceProvider {
  static const _connectTimeout = Duration(seconds: 15);
  static const _ioTimeout = Duration(seconds: 30);
  final ServerConfig config;
  final String password;
  final CacheManager? cacheManager;
  Smb2Client? _client;
  Smb2Tree? _tree;

  /// Cached ZipReader futures keyed by ZIP file path.
  /// Using Future cache prevents duplicate _parseDirectory on concurrent calls.
  final Map<String, Future<ZipReader>> _zipReaderFutures = {};

  static const _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  };

  static const _zipExtensions = {'.zip'};
  static const _pdfExtensions = {'.pdf'};

  /// Cached PDF bytes keyed by file path.
  final Map<String, Uint8List> _pdfBytesCache = {};

  Future<Smb2Tree>? _connectFuture;

  SmbSource({required this.config, required this.password, this.cacheManager});

  Future<Smb2Tree> _connect() {
    // Detect dead connection and reset for reconnect
    if (_client != null && !_client!.isConnected) {
      _log.info('Connection lost, will reconnect (SmbSource@${hashCode.toRadixString(16)}, client@${_client!.hashCode.toRadixString(16)})');
      _client = null;
      _tree = null;
      _connectFuture = null;
      _zipReaderFutures.clear();
    }
    return _connectFuture ??= _doConnect();
  }

  Future<Smb2Tree> _doConnect() async {
    final share = config.shareName ?? '';
    _log.info('Connecting to ${config.host}/$share... (SmbSource@${hashCode.toRadixString(16)})');
    try {
      _client = await Smb2Client.connect(
        host: config.host,
        port: config.port,
        username: config.username ?? '',
        password: password,
      ).timeout(_connectTimeout);
      _log.info('Connected: dialect=${Smb2Dialect.describe(_client!.dialectRevision)}, '
          'maxRead=${_client!.maxReadSize}, client@${_client!.hashCode.toRadixString(16)}');
      _tree = await _client!.connectTree(share).timeout(_connectTimeout);
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
    final files = await tree.listDirectory(dirPath).timeout(_ioTimeout);

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
      } else if (_pdfExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: 'smb:${config.id}:${file.path}',
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: smbSourceKey,
          metadata: {
            'isDirectory': false,
            'isPdf': true,
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

  /// Get or create a ZipReader for the given ZIP path.
  Future<ZipReader> _getZipReader(String zipPath) =>
      _zipReaderFutures[zipPath] ??= _createZipReader(zipPath);

  Future<ZipReader> _createZipReader(String zipPath) async {
    final tree = await _connect();
    final reader = await tree.openRead(zipPath).timeout(_ioTimeout);
    final fileSize = reader.fileSize;
    await reader.close();

    return ZipReader(
      readRange: (offset, length) => _readRange(zipPath, offset, length),
      fileSize: fileSize,
    );
  }

  /// Range read for a specific file path via SMB.
  Future<Uint8List> _readRange(String path, int offset, int length) async {
    final tree = await _connect();
    final reader = await tree.openRead(path).timeout(_ioTimeout);
    try {
      return await reader.readRange(offset, length).timeout(_ioTimeout);
    } finally {
      try {
        await reader.close();
      } catch (e, st) {
        _log.warning('close error in _readRange', e, st);
      }
    }
  }

  @override
  Future<List<ImageSource>> resolvePages(ImageSource source) async {
    if (source.metadata?['isPdf'] == true) {
      return _resolvePdfPages(source);
    }
    if (source.metadata?['isZip'] != true) return [source];

    final zipPath = source.uri;
    final smbSourceKey = 'smb:${config.id}';
    _log.info('resolvePages: reading ZIP directory $zipPath');

    final zipReader = await _getZipReader(zipPath);
    final allEntries = await zipReader.listEntries();

    // All non-directory entries, sorted naturally
    final fileEntries = allEntries
        .where((e) => !e.isDirectory)
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));

    _log.info('resolvePages: ${fileEntries.length} files in ZIP '
        '(${allEntries.length} total entries, read directory only, no full download)');

    final pages = <ImageSource>[];
    for (var i = 0; i < fileEntries.length; i++) {
      final entry = fileEntries[i];
      final pageId = 'smb:${config.id}:$zipPath#${entry.name}';
      final isSupported = _isImageName(entry.name);

      pages.add(ImageSource(
        id: pageId,
        name: '${source.name} (${i + 1}/${fileEntries.length}) ${entry.name}',
        uri: '$zipPath#${entry.name}',
        type: ImageSourceType.smb,
        sourceKey: smbSourceKey,
        metadata: {
          'isDirectory': false,
          'isZipEntry': true,
          'zipPath': zipPath,
          'entryName': entry.name,
          'path': source.metadata?['path'],
          if (!isSupported) 'unsupported': true,
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
    // PDF files: no thumbnail support for now
    if (source.metadata?['isPdf'] == true) {
      throw ThumbnailNotSupportedException('PDF: ${source.name}');
    }

    // ZIP files: read first image from ZIP directory via range read
    if (source.metadata?['isZip'] == true) {
      final zipPath = source.uri;
      try {
        final zipReader = await _getZipReader(zipPath);
        final entries = await zipReader.listEntries();
        final imageEntries = entries
            .where((e) => !e.isDirectory && _isImageName(e.name))
            .toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
        if (imageEntries.isEmpty) {
          throw ThumbnailNotSupportedException('ZIP has no images: ${source.name}');
        }
        final firstImage = await zipReader.readEntry(imageEntries.first);
        _log.info('ZIP thumbnail: ${imageEntries.first.name} (${firstImage.length} bytes)');
        return (data: firstImage, isFullImage: true);
      } catch (e, st) {
        if (e is ThumbnailNotSupportedException) rethrow;
        _log.warning('ZIP thumbnail failed, falling back: ${source.name}', e, st);
        throw ThumbnailNotSupportedException('ZIP: ${source.name}');
      }
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
    final reader = await tree.openRead(path).timeout(_ioTimeout);
    try {
      return await reader.readRange(0, length).timeout(_ioTimeout);
    } finally {
      try {
        await reader.close();
      } catch (e, st) {
        _log.warning('close error in _readPartial', e, st);
      }
    }
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) async {
    // PDF pages: render from cached PDF bytes
    if (source.metadata?['isPdfPage'] == true) {
      final pdfPath = source.metadata!['pdfPath'] as String;
      final pdfCacheKey = source.metadata!['pdfCacheKey'] as String;
      final pageIndex = source.metadata!['pageIndex'] as int;
      return _renderPdfPage(pdfPath, pdfCacheKey, pageIndex);
    }

    // ZIP entries: read individual file via range read
    if (source.metadata?['isZipEntry'] == true) {
      // Check cache first
      if (cacheManager != null) {
        final cacheKey = 'full:${source.id}';
        final cached = await cacheManager!.get(cacheKey);
        if (cached != null) {
          _log.info('ZIP entry from cache: ${source.name} (${cached.data.length} bytes)');
          return Uint8List.fromList(cached.data);
        }
      }

      // Range read from ZIP
      final zipPath = source.metadata!['zipPath'] as String;
      final entryName = source.metadata!['entryName'] as String;
      final zipReader = await _getZipReader(zipPath);
      final entries = await zipReader.listEntries();
      final entry = entries.firstWhere((e) => e.name == entryName);
      final data = await zipReader.readEntry(entry);
      _log.info('ZIP entry via range read: ${source.name} (${data.length} bytes)');

      // Cache the result
      if (cacheManager != null) {
        await cacheManager!.l2.put('full:${source.id}', data);
      }
      return data;
    }

    final stopwatch = Stopwatch()..start();
    final tree = await _connect();
    final reader = await tree.openRead(source.uri).timeout(_ioTimeout);
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

  /// Resolve PDF pages: download full PDF, count pages, return page list.
  Future<List<ImageSource>> _resolvePdfPages(ImageSource source) async {
    final pdfPath = source.uri;
    final smbSourceKey = 'smb:${config.id}';

    // Check L2 cache for PDF bytes, then memory cache, then download
    final pdfCacheKey = 'full:${source.id}';
    Uint8List pdfBytes;
    final cached = cacheManager != null ? await cacheManager!.get(pdfCacheKey) : null;
    if (cached != null) {
      pdfBytes = Uint8List.fromList(cached.data);
      _log.info('resolvePages: PDF from cache (${(pdfBytes.length / 1024).toStringAsFixed(0)} KB, ${cached.source})');
    } else {
      _log.info('resolvePages: downloading PDF $pdfPath');
      pdfBytes = await _downloadFile(pdfPath);
      _log.info('resolvePages: PDF downloaded (${(pdfBytes.length / 1024).toStringAsFixed(0)} KB)');
      // Store in L1 + L2
      if (cacheManager != null) {
        cacheManager!.l1.put(pdfCacheKey, pdfBytes);
        await cacheManager!.l2.put(pdfCacheKey, pdfBytes);
      }
    }
    _pdfBytesCache[pdfPath] = pdfBytes;

    // Get page count from PDF metadata (no rasterization)
    final doc = await PdfDocument.openData(pdfBytes);
    final pageCount = doc.pages.length;
    await doc.dispose();
    _log.info('resolvePages: $pageCount pages in PDF');

    final pages = <ImageSource>[];
    for (var i = 0; i < pageCount; i++) {
      pages.add(ImageSource(
        id: 'smb:${config.id}:$pdfPath#page$i',
        name: '${source.name} (${i + 1}/$pageCount)',
        uri: '$pdfPath#page$i',
        type: ImageSourceType.smb,
        sourceKey: smbSourceKey,
        metadata: {
          'isDirectory': false,
          'isPdfPage': true,
          'pdfPath': pdfPath,
          'pdfCacheKey': pdfCacheKey,
          'pageIndex': i,
          'path': source.metadata?['path'],
        },
      ));
    }
    return pages;
  }

  /// Render a single PDF page to PNG.
  Future<Uint8List> _renderPdfPage(String pdfPath, String pdfCacheKey, int pageIndex) async {
    var pdfBytes = _pdfBytesCache[pdfPath];
    if (pdfBytes == null && cacheManager != null) {
      // Restore from L2 cache
      final cached = await cacheManager!.get(pdfCacheKey);
      if (cached != null) {
        pdfBytes = Uint8List.fromList(cached.data);
        _pdfBytesCache[pdfPath] = pdfBytes;
        _log.info('PDF bytes restored from cache for $pdfPath');
      }
    }
    if (pdfBytes == null) {
      throw StateError('PDF not cached: $pdfPath');
    }

    _log.info('Rendering PDF page $pageIndex from $pdfPath');
    final doc = await PdfDocument.openData(pdfBytes);
    try {
      final page = doc.pages[pageIndex];
      // Render at 2x page size for good quality
      final pdfImage = await page.render(
        fullWidth: page.width * 2,
        fullHeight: page.height * 2,
      );
      if (pdfImage == null) {
        throw StateError('Failed to render PDF page $pageIndex');
      }
      try {
        final image = await pdfImage.createImage();
        try {
          final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
          if (byteData == null) {
            throw StateError('Failed to encode PDF page $pageIndex as PNG');
          }
          final png = byteData.buffer.asUint8List();
          _log.info('Rendered PDF page $pageIndex: ${(png.length / 1024).toStringAsFixed(0)} KB');
          return png;
        } finally {
          image.dispose();
        }
      } finally {
        pdfImage.dispose();
      }
    } finally {
      await doc.dispose();
    }
  }

  /// Download an entire file from SMB.
  Future<Uint8List> _downloadFile(String path) async {
    final tree = await _connect();
    final reader = await tree.openRead(path).timeout(_ioTimeout);
    try {
      final chunks = <Uint8List>[];
      int received = 0;
      await for (final chunk in reader.readStream()) {
        chunks.add(chunk);
        received += chunk.length;
      }
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
    _zipReaderFutures.clear();
    _pdfBytesCache.clear();
    _connectFuture = null;
    if (_client != null) {
      await _client!.disconnect();
      _client = null;
      _tree = null;
    }
  }
}
