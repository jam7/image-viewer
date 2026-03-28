import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../sources/smb_source.dart';

final _log = Logger('SmbProxy');

class _ProxySession {
  final SmbSource source;
  final String filePath;
  final int fileSize;
  bool cancelled = false;
  _ProxySession(this.source, this.filePath, this.fileSize);
}

/// Local HTTP proxy that bridges media_kit ↔ SMB.
/// Binds to 127.0.0.1 on a random port. Each session gets a one-time token.
class SmbProxyServer {
  HttpServer? _server;
  int get port => _server?.port ?? 0;

  final _sessions = <String, _ProxySession>{};
  final _random = Random.secure();

  Future<void> start() async {
    if (_server != null) {
      // Verify the server is still alive (iOS kills background sockets)
      try {
        final testSocket = await Socket.connect('127.0.0.1', _server!.port,
            timeout: const Duration(seconds: 1));
        testSocket.destroy();
      } catch (_) {
        _log.info('Proxy server dead, restarting');
        try { await _server!.close(); } catch (_) {}
        _server = null;
      }
    }
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _log.info('Proxy started on 127.0.0.1:${_server!.port}');
    _server!.listen(_handleRequest);
  }

  /// Register a session and return the playback URL.
  Future<String> registerSession(SmbSource source, String filePath) async {
    await start();
    final token = _generateToken();
    final tree = await source.connectForProxy();
    final reader = await tree.openRead(filePath);
    final fileSize = reader.fileSize;
    await reader.close();

    _sessions[token] = _ProxySession(source, filePath, fileSize);
    final url = 'http://127.0.0.1:$port/$token';
    _log.info('Session registered: $filePath ($fileSize bytes) → $url');
    return url;
  }

  void invalidateToken(String token) {
    final session = _sessions.remove(token);
    if (session != null) {
      session.cancelled = true;
    }
    _log.info('Token invalidated');
  }

  Future<void> dispose() async {
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
    _log.info('Proxy stopped');
  }

  String _generateToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final token = request.uri.pathSegments.isNotEmpty
        ? request.uri.pathSegments.first
        : '';
    final session = _sessions[token];
    if (session == null) {
      _log.info('403: invalid token (${request.method} ${request.headers.value('range') ?? 'no-range'})');
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final rangeLog = request.headers.value('range') ?? 'full';
    _log.info('Request: ${session.filePath.split('\\').last} $rangeLog');

    try {
      final rangeHeader = request.headers.value('range');
      int start = 0;
      int end = session.fileSize - 1;

      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) {
            end = int.parse(match.group(2)!);
          }
        }
      }

      final length = end - start + 1;

      if (rangeHeader != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('content-range', 'bytes $start-$end/${session.fileSize}');
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      request.response.headers.set('content-length', length);
      request.response.headers.set('content-type', 'application/octet-stream');
      request.response.headers.set('accept-ranges', 'bytes');

      // Stream data in chunks matching SMB max read size
      const chunkSize = 1024 * 1024; // 1MB
      int offset = start;
      int remaining = length;
      while (remaining > 0 && !session.cancelled) {
        final readLen = remaining < chunkSize ? remaining : chunkSize;
        Uint8List data;
        try {
          data = await session.source.readRange(session.filePath, offset, readLen);
        } catch (e) {
          // Retry once on connection error (triggers SMB reconnect)
          _log.info('readRange failed, retrying: $e');
          data = await session.source.readRange(session.filePath, offset, readLen);
        }
        request.response.add(data);
        offset += data.length;
        remaining -= data.length;
      }
      await request.response.close();
      if (session.cancelled) {
        _log.info('Response aborted: ${session.filePath.split('\\').last}');
      } else {
        _log.info('Response done: ${session.filePath.split('\\').last} ${length ~/ 1024}KB');
      }
    } catch (e, st) {
      _log.warning('Proxy request error: ${session.filePath.split('\\').last}', e, st);
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }
}
