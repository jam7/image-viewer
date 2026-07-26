import 'dart:typed_data';

import 'package:archive_reader/archive_reader.dart';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:exif/exif.dart';
import 'package:flutter/painting.dart';
import 'package:logging/logging.dart';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../../models/media_extensions.dart';
import '../../models/smb_identity.dart';
import '../../models/image_source.dart';
import '../../models/server_config.dart';
import '../../utils/natural_sort.dart';
import '../cache/cache_manager.dart';
import '../video/smb_proxy_server.dart';
import '../video/video_thumbnail_service.dart';
import 'image_source_provider.dart';

final _log = Logger('SMB');

/// SMB2経由の画像取得。
class SmbSource extends ImageSourceProvider {
  static const _connectTimeout = Duration(seconds: 15);
  static const _ioTimeout = Duration(seconds: 30);
  static const _thumbnailMaxSize = 600;
  final ServerConfig config;
  final String password;
  final CacheManager? cacheManager;
  /// Local HTTP proxy used to feed SMB video bytes to media_kit for video
  /// thumbnail capture. Null disables video thumbnails (fetchThumbnail throws
  /// notSupported for videos).
  final SmbProxyServer? proxyServer;
  Smb2Client? _client;
  Smb2Tree? _tree;
  /// Reused media_kit player for video thumbnail capture. Released by
  /// [cancelThumbnailWork] (e.g. before playing a video) and [dispose].
  VideoThumbnailService? _videoThumbService;

  /// Cached ZipReader futures keyed by ZIP file path.
  /// Using Future cache prevents duplicate _parseDirectory on concurrent calls.
  final Map<String, Future<ZipReader>> _zipReaderFutures = {};


  /// Cached PDF file paths keyed by PDF source path.
  final Map<String, String> _pdfFilePathCache = {};
  /// Future cache to prevent duplicate concurrent PDF downloads.
  final Map<String, Future<String>> _pdfDownloadFutures = {};

  /// Cached PdfDocument for avoiding repeated open/close on large PDFs.
  String? _cachedPdfPath;
  PdfDocument? _cachedPdfDoc;

  Future<Smb2Tree>? _connectFuture;

  SmbSource({
    required this.config,
    required this.password,
    this.cacheManager,
    this.proxyServer,
  });

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

      final sourceKey = smbSourceKey(config.id);
      if (file.isDirectory) {
        sources.add(ImageSource(
          id: smbItemId(config.id, file.path),
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: sourceKey,
          metadata: {
            'isDirectory': true,
            'path': file.path,
          },
        ));
      } else if (imageExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: smbItemId(config.id, file.path),
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: sourceKey,
          metadata: {
            'isDirectory': false,
            'path': file.path,
          },
        ));
      } else if (zipExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: smbItemId(config.id, file.path),
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: sourceKey,
          metadata: {
            'isDirectory': false,
            'isZip': true,
            'path': file.path,
          },
        ));
      } else if (pdfExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: smbItemId(config.id, file.path),
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: sourceKey,
          metadata: {
            'isDirectory': false,
            'isPdf': true,
            'path': file.path,
          },
        ));
      } else if (videoExtensions.contains(ext)) {
        sources.add(ImageSource(
          id: smbItemId(config.id, file.path),
          name: name,
          uri: file.path,
          type: ImageSourceType.smb,
          sourceKey: sourceKey,
          metadata: {
            'isDirectory': false,
            'isVideo': true,
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
      readRange: (offset, length) => readRange(zipPath, offset, length),
      fileSize: fileSize,
    );
  }

  /// Expose connect for proxy server.
  Future<Smb2Tree> connectForProxy() => _connect();

  /// Range read for a specific file path via SMB.
  /// Small ranges go out as a compound Create+Read+Close (1 round trip).
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final tree = await _connect();
    return tree.readRange(path, offset: offset, length: length).timeout(_ioTimeout);
  }

  @override
  Future<List<ImageSource>> resolvePages(ImageSource source) =>
      _asItem(source.uri, () => _resolvePages(source));

  Future<List<ImageSource>> _resolvePages(ImageSource source) async {
    if (source.metadata?['isPdf'] == true) {
      return _resolvePdfPages(source);
    }
    if (source.metadata?['isZip'] != true) return [source];

    final zipPath = source.uri;
    final sourceKey = smbSourceKey(config.id);
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
      final pageId = smbItemId(config.id, '$zipPath#${entry.name}');
      final isSupported = _isImageName(entry.name);

      pages.add(ImageSource(
        id: pageId,
        name: '${source.name} (${i + 1}/${fileEntries.length}) ${entry.name}',
        uri: '$zipPath#${entry.name}',
        type: ImageSourceType.smb,
        sourceKey: sourceKey,
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
    return imageExtensions.any((ext) => lower.endsWith(ext));
  }

  /// Capture a thumbnail frame for a video by streaming it through the local
  /// HTTP proxy into media_kit, then resizing. The reused player is released by
  /// [cancelThumbnailWork]. Throws if no proxy is configured or capture fails.
  Future<Uint8List> _captureVideoThumbnail(ImageSource source) async {
    final proxy = proxyServer;
    if (proxy == null) {
      throw ThumbnailNotSupportedException('Video (no proxy): ${source.name}');
    }
    final url = await proxy.registerSession(this, source.uri);
    final token = url.split('/').last;
    try {
      _videoThumbService ??= VideoThumbnailService();
      final bytes = await _videoThumbService!.capture(url);
      if (bytes == null) {
        throw Exception('Video capture returned null: ${source.name}');
      }
      final resized = await resizeToThumbnail(bytes);
      _log.info('Video thumbnail: ${source.name} '
          '(${(bytes.length / 1024).toStringAsFixed(0)} KB -> '
          '${(resized.length / 1024).toStringAsFixed(0)} KB)');
      return resized;
    } finally {
      proxy.invalidateToken(token);
    }
  }

  @override
  Future<Uint8List> fetchThumbnail(ImageSource source) async {
    // Video: capture a frame via the local HTTP proxy + media_kit, then resize.
    if (source.metadata?['isVideo'] == true) {
      return _captureVideoThumbnail(source);
    }

    // PDF: render page 0 if cached locally
    if (source.metadata?['isPdf'] == true) {
      final pdfCacheKey = 'full:${source.id}';
      final filePath = cacheManager?.getFilePath(pdfCacheKey);
      if (filePath == null) {
        throw ThumbnailNotSupportedException('PDF not cached: ${source.name}');
      }
      try {
        final png = await _renderPdfThumbnail(filePath);
        _log.info('PDF thumbnail: ${source.name} (${(png.length / 1024).toStringAsFixed(0)} KB)');
        return png;
      } catch (e, st) {
        _log.warning('PDF thumbnail failed: ${source.name}', e, st);
        throw ThumbnailNotSupportedException('PDF: ${source.name}');
      }
    }

    // ZIP: read first image from ZIP directory via range read
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
        return resizeToThumbnail(firstImage);
      } catch (e, st) {
        if (e is ThumbnailNotSupportedException) rethrow;
        _log.warning('ZIP thumbnail failed: ${source.name}', e, st);
        throw ThumbnailNotSupportedException('ZIP: ${source.name}');
      }
    }

    // JPEG: try EXIF thumbnail first
    final name = source.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
      final exifBytes = await _tryExifThumbnail(source);
      if (exifBytes != null) {
        return resizeToThumbnail(exifBytes);
      }
    }

    // Fallback: full image → resize
    final fullData = await fetchFullImage(source);
    return resizeToThumbnail(fullData);
  }

  /// JPEG ヘッダ部の EXIF サムネイルを試す。十分な解像度のものが取れなければ
  /// null を返し、呼び出し側がフル画像にフォールバックする。
  Future<Uint8List?> _tryExifThumbnail(ImageSource source) async {
    try {
      final header = await _readPartial(source.uri, 65536);
      final exifData = await readExifFromBytes(header);
      final thumbnail = exifData['JPEGThumbnail'];
      if (thumbnail == null) return null;
      final bytes = thumbnail.values.toList();
      if (bytes.isEmpty) return null;

      final exifBytes = Uint8List.fromList(bytes.cast<int>());
      final exifSize = await _getImageSize(exifBytes);
      if (exifSize == null ||
          (exifSize.width < _thumbnailMaxSize &&
              exifSize.height < _thumbnailMaxSize)) {
        _log.info('EXIF thumbnail too small '
            '(${exifSize?.width}x${exifSize?.height}), using full image: ${source.name}');
        return null;
      }
      _log.info('EXIF thumbnail: ${source.name} '
          '(${exifSize.width}x${exifSize.height})');
      return exifBytes;
    } catch (e, st) {
      _log.warning('EXIF parse error, using full image: ${source.name}', e, st);
      return null;
    }
  }

  /// ファイルの先頭 [length] バイトだけ読み込む。
  /// Compound Create+Read+Close (1 round trip) for small lengths.
  Future<Uint8List> _readPartial(String path, int length) async {
    final tree = await _connect();
    return tree.readRange(path, offset: 0, length: length).timeout(_ioTimeout);
  }

  /// Reading a path the server turns out to consider a directory. Only an
  /// address from outside can be wrong this way — the app's own say which they
  /// are — so it is reported as such rather than as a failed read, and the
  /// caller can go to the listing instead (ADR 010).
  Future<T> _asItem<T>(String path, Future<T> Function() read) async {
    try {
      return await read();
    } on Smb2Exception catch (e) {
      if (e.status != NtStatus.fileIsADirectory) rethrow;
      throw NotAnItemException(path);
    }
  }

  @override
  Future<Uint8List> fetchFullImage(
    ImageSource source, {
    void Function(int received, int total)? onProgress,
  }) async =>
      _asItem(source.uri, () => _fetchFullImage(source, onProgress: onProgress));

  Future<Uint8List> _fetchFullImage(
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

  @override
  Future<({Stream<Uint8List> stream, int fileSize, Future<void> Function() close})> openReadStream(
    ImageSource source,
  ) async {
    final tree = await _connect();
    final reader = await tree.openRead(source.uri).timeout(_ioTimeout);
    return (stream: reader.readStream(), fileSize: reader.fileSize, close: () => reader.close());
  }

  /// Resolve PDF pages: download full PDF, count pages, return page list.
  Future<List<ImageSource>> _resolvePdfPages(ImageSource source) async {
    final pdfPath = source.uri;
    final sourceKey = smbSourceKey(config.id);

    // Get PDF file path from cache, or download to L2
    final pdfCacheKey = 'full:${source.id}';
    final pdfFilePath = await _ensurePdfFile(pdfPath, pdfCacheKey);

    // Get page count from PDF metadata (no rasterization)
    final doc = await _openPdfCached(pdfFilePath);
    final pageCount = doc.pages.length;
    _log.info('resolvePages: $pageCount pages in PDF');

    final pages = <ImageSource>[];
    for (var i = 0; i < pageCount; i++) {
      pages.add(ImageSource(
        id: smbItemId(config.id, '$pdfPath#page$i'),
        name: '${source.name} (${i + 1}/$pageCount)',
        uri: '$pdfPath#page$i',
        type: ImageSourceType.smb,
        sourceKey: sourceKey,
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

  /// Ensure PDF file is available on local disk. Returns file path.
  /// Uses Future cache to prevent duplicate concurrent downloads.
  Future<String> _ensurePdfFile(String pdfPath, String pdfCacheKey) {
    // Check in-memory path cache (synchronous)
    final cachedPath = _pdfFilePathCache[pdfPath];
    if (cachedPath != null) return Future.value(cachedPath);

    // Use Future cache to prevent duplicate downloads.
    // The cleanup callback MUST NOT return Map.remove's result: the removed
    // value is this very future, and whenComplete waits for a returned
    // future before completing — i.e. `() => _pdfDownloadFutures.remove(...)`
    // deadlocks on itself and the caller's await never resumes.
    return _pdfDownloadFutures[pdfPath] ??= _ensurePdfFileImpl(pdfPath, pdfCacheKey)
        .whenComplete(() {
      _pdfDownloadFutures.remove(pdfPath);
    });
  }

  Future<String> _ensurePdfFileImpl(String pdfPath, String pdfCacheKey) async {
    // Check L2/L3 cache for existing file
    if (cacheManager != null) {
      final filePath = cacheManager!.getFilePath(pdfCacheKey);
      if (filePath != null) {
        _log.info('resolvePages: PDF from cache file');
        _pdfFilePathCache[pdfPath] = filePath;
        return filePath;
      }
    }

    // Download from SMB and store in L2
    _log.info('resolvePages: downloading PDF $pdfPath');
    final pdfBytes = await _downloadFile(pdfPath);
    _log.info('resolvePages: PDF downloaded (${(pdfBytes.length / 1024).toStringAsFixed(0)} KB)');
    if (cacheManager != null) {
      await cacheManager!.l2.put(pdfCacheKey, pdfBytes);
      final filePath = cacheManager!.l2.getFilePath(pdfCacheKey);
      if (filePath != null) {
        _pdfFilePathCache[pdfPath] = filePath;
        return filePath;
      }
    }

    // Fallback: should not happen if cacheManager is set
    throw StateError('Failed to cache PDF file: $pdfPath');
  }

  /// Get or open a cached PdfDocument. Disposes previous if different file.
  Future<PdfDocument> _openPdfCached(String filePath) async {
    if (_cachedPdfPath == filePath && _cachedPdfDoc != null) {
      return _cachedPdfDoc!;
    }
    await _closePdfCache();
    // Deliberate operational logs: document opens are infrequent, and a
    // hang inside PdfDocument.openFile is invisible without the pair
    // (pdfrx 2.4.x froze exactly here — see docs/reviews/20260703-...).
    _log.info('openPdf: opening $filePath');
    final doc = await PdfDocument.openFile(filePath);
    _log.info('openPdf: opened ${doc.pages.length} pages');
    _cachedPdfDoc = doc;
    _cachedPdfPath = filePath;
    return doc;
  }

  Future<void> _closePdfCache() async {
    if (_cachedPdfDoc != null) {
      await _cachedPdfDoc!.dispose();
      _cachedPdfDoc = null;
      _cachedPdfPath = null;
    }
  }

  /// Render a single PDF page to PNG.
  Future<Uint8List> _renderPdfPage(String pdfPath, String pdfCacheKey, int pageIndex) async {
    final pdfFilePath = await _ensurePdfFile(pdfPath, pdfCacheKey);
    _log.info('Rendering PDF page $pageIndex from $pdfPath');
    return _renderPdfPageFrom(pdfFilePath, pageIndex, scale: 2.0);
  }

  /// Render a PDF page to PNG at given scale.
  Future<Uint8List> _renderPdfPageFrom(String filePath, int pageIndex, {required double scale}) async {
    final doc = await _openPdfCached(filePath);
    final page = doc.pages[pageIndex];
    final pdfImage = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
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

  /// Get image dimensions without full decode.
  Future<ui.Size?> _getImageSize(Uint8List data) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(data);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (e) {
      return null;
    }
  }

  /// Resize image data so the long edge is at most [_thumbnailMaxSize] px.
  /// If data is <= [_thumbnailMaxBytes], returns as-is (avoids JPEG→PNG size increase).
  /// Otherwise returns PNG bytes.
  static const _thumbnailMaxBytes = 400 * 1024; // 400KB

  Future<Uint8List> resizeToThumbnail(Uint8List data) async {
    if (data.length <= _thumbnailMaxBytes) {
      _log.info('Thumbnail skip resize: ${(data.length / 1024).toStringAsFixed(0)} KB <= ${_thumbnailMaxBytes ~/ 1024} KB');
      return data;
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(data);
    int? origW, origH;
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        origW = w;
        origH = h;
        final longEdge = w > h ? w : h;
        if (longEdge <= _thumbnailMaxSize) return ui.TargetImageSize(width: w, height: h);
        final scale = _thumbnailMaxSize / longEdge;
        return ui.TargetImageSize(
          width: (w * scale).round(),
          height: (h * scale).round(),
        );
      },
    );
    final frame = await codec.getNextFrame();
    _log.info('Thumbnail resize: ${origW}x$origH → ${frame.image.width}x${frame.image.height} (input ${(data.length / 1024).toStringAsFixed(0)} KB)');
    final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return byteData!.buffer.asUint8List();
  }

  /// Render PDF page 0 as a thumbnail with long edge [_thumbnailMaxSize] px.
  Future<Uint8List> _renderPdfThumbnail(String filePath) async {
    final doc = await _openPdfCached(filePath);
    final page = doc.pages[0];
    final longEdge = page.width > page.height ? page.width : page.height;
    final scale = _thumbnailMaxSize / longEdge;
    return _renderPdfPageFrom(filePath, 0, scale: scale);
  }

  /// Release the video thumbnail player (e.g. before playing a video, so the
  /// player screen gets the SMB connection). Called by ThumbnailLoader.cancel().
  @override
  void cancelThumbnailWork() {
    _videoThumbService?.dispose();
    _videoThumbService = null;
  }

  @override
  Future<void> dispose() async {
    _zipReaderFutures.clear();
    _pdfFilePathCache.clear();
    _pdfDownloadFutures.clear();
    await _closePdfCache();
    _videoThumbService?.dispose();
    _videoThumbService = null;
    _connectFuture = null;
    if (_client != null) {
      await _client!.disconnect();
      _client = null;
      _tree = null;
    }
  }
}
