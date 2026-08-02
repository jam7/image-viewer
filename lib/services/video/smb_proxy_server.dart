import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
    final tree = await source.connectForProxy();
    final reader = await tree.openRead(filePath);
    final fileSize = reader.fileSize;
    await reader.close();
    return _register(source, filePath, fileSize);
  }

  /// The same, for a file whose size is already known. Learning it is the one
  /// thing here that needs an SMB server to exist.
  @visibleForTesting
  Future<String> registerKnownSession(
      SmbSource source, String filePath, int fileSize) async {
    await start();
    return _register(source, filePath, fileSize);
  }

  String _register(SmbSource source, String filePath, int fileSize) {
    final token = _generateToken();
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
    final rangeHeader = request.headers.value('range');
    _log.info('Request: ${_nameOf(session)} ${rangeHeader ?? 'full'}');

    try {
      final asked = _rangeAsked(rangeHeader, session.fileSize);
      _writeHeaders(request.response, asked, session.fileSize,
          partial: rangeHeader != null);
      await _streamRange(request.response, session, asked);
      await request.response.close();
      if (session.cancelled) {
        _log.info('Response aborted: ${_nameOf(session)}');
      } else {
        _log.info('Response done: ${_nameOf(session)} ${asked.length ~/ 1024}KB');
      }
    } catch (e, st) {
      _log.warning('Proxy request error: ${_nameOf(session)}', e, st);
      await _failRequest(request.response);
    }
  }

  /// The window the player asked for, defaulting to the whole file. A Range
  /// header that does not parse is answered with the whole file as well —
  /// media_kit does not send one, and guessing at a malformed one is worse
  /// than sending everything.
  _ByteRange _rangeAsked(String? rangeHeader, int fileSize) {
    var start = 0;
    var end = fileSize - 1;
    final match = rangeHeader == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
    if (match != null) {
      start = int.parse(match.group(1)!);
      if (match.group(2)!.isNotEmpty) {
        end = int.parse(match.group(2)!);
      }
    }
    return _ByteRange(start, end);
  }

  void _writeHeaders(
    HttpResponse response,
    _ByteRange range,
    int fileSize, {
    required bool partial,
  }) {
    if (partial) {
      response.statusCode = HttpStatus.partialContent;
      response.headers
          .set('content-range', 'bytes ${range.start}-${range.end}/$fileSize');
    } else {
      response.statusCode = HttpStatus.ok;
    }
    response.headers.set('content-length', range.length);
    response.headers.set('content-type', 'application/octet-stream');
    response.headers.set('accept-ranges', 'bytes');
  }

  /// Reads the window a piece at a time, checking before each piece whether
  /// the session is still wanted: the player is closed by invalidating its
  /// token, and reading on would hold an SMB connection the next one needs.
  Future<void> _streamRange(
      HttpResponse response, _ProxySession session, _ByteRange range) async {
    // Chunks match the SMB max read size
    const chunkSize = 1024 * 1024; // 1MB
    var offset = range.start;
    var remaining = range.length;
    while (remaining > 0 && !session.cancelled) {
      final readLen = remaining < chunkSize ? remaining : chunkSize;
      final data = await _readRetrying(session, offset, readLen);
      response.add(data);
      offset += data.length;
      remaining -= data.length;
    }
  }

  Future<Uint8List> _readRetrying(
      _ProxySession session, int offset, int length) async {
    try {
      return await session.source.readRange(session.filePath, offset, length);
    } catch (e) {
      // Retry once on connection error (triggers SMB reconnect)
      _log.info('readRange failed, retrying: $e');
      return session.source.readRange(session.filePath, offset, length);
    }
  }

  Future<void> _failRequest(HttpResponse response) async {
    try {
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    } catch (e) {
      // Nothing left to say it with: the headers went out long before the
      // read that failed, so the player sees a short body and a closed
      // connection either way.
      _log.info('could not report the failure to the player: $e');
    }
  }

  String _nameOf(_ProxySession session) => session.filePath.split('\\').last;
}

class _ByteRange {
  final int start;
  final int end;

  const _ByteRange(this.start, this.end);

  int get length => end - start + 1;
}
