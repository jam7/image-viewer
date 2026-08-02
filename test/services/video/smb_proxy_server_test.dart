import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_viewer/models/image_source.dart';
import 'package:image_viewer/models/server_config.dart';
import 'package:image_viewer/services/sources/smb_source.dart';
import 'package:image_viewer/services/video/smb_proxy_server.dart';

/// media_kit cannot read SMB, so it reads HTTP from here instead (ADR 002).
/// What it relies on is the Range protocol: it seeks by asking for byte
/// windows, and a wrong content-range or a body that stops early is a video
/// that will not scrub.
void main() {
  late SmbProxyServer proxy;
  late _FakeSmb smb;

  const chunk = 1024 * 1024; // what the proxy reads at a time

  setUp(() {
    proxy = SmbProxyServer();
    smb = _FakeSmb();
  });

  tearDown(() => proxy.dispose());

  /// The bytes the file is made of: recognisable at any offset, so a slice
  /// says where it came from.
  int byteAt(int offset) => offset % 251;

  Future<(HttpClientResponse, List<int>)> fetch(String url,
      {String? range}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (range != null) request.headers.set('range', range);
      final response = await request.close();
      final body = <int>[];
      await for (final part in response) {
        body.addAll(part);
      }
      return (response, body);
    } finally {
      client.close();
    }
  }

  test('without a Range header the whole file comes back', () async {
    final url = await proxy.registerKnownSession(smb, 'movie.mp4', 100);

    final (response, body) = await fetch(url);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value('content-length'), '100');
    expect(response.headers.value('accept-ranges'), 'bytes');
    expect(body.length, 100);
    expect(body.first, byteAt(0));
    expect(body.last, byteAt(99));
  });

  test('a Range is answered with 206 and the window it asked for', () async {
    final url = await proxy.registerKnownSession(smb, 'movie.mp4', 100);

    final (response, body) = await fetch(url, range: 'bytes=10-19');

    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value('content-range'), 'bytes 10-19/100');
    expect(response.headers.value('content-length'), '10');
    expect(body, [for (var i = 10; i <= 19; i++) byteAt(i)]);
    expect(smb.reads, [(10, 10)]);
  });

  test('an open-ended Range runs to the last byte', () async {
    final url = await proxy.registerKnownSession(smb, 'movie.mp4', 100);

    final (response, body) = await fetch(url, range: 'bytes=90-');

    expect(response.headers.value('content-range'), 'bytes 90-99/100');
    expect(body.length, 10);
  });

  test('a file larger than the read size arrives in one piece', () async {
    // The player asks for windows of its own choosing; the proxy's 1MB reads
    // have to be invisible to it.
    final url =
        await proxy.registerKnownSession(smb, 'movie.mp4', chunk * 2 + 512);

    final (_, body) = await fetch(url);

    expect(body.length, chunk * 2 + 512);
    expect(smb.reads, [(0, chunk), (chunk, chunk), (chunk * 2, 512)]);
    expect(body[chunk + 7], byteAt(chunk + 7));
  });

  test('an unknown token is refused', () async {
    await proxy.registerKnownSession(smb, 'movie.mp4', 100);

    final (response, _) = await fetch('http://127.0.0.1:${proxy.port}/nope');

    expect(response.statusCode, HttpStatus.forbidden);
  });

  test('invalidating the token stops the reading', () async {
    // Closing the player must stop the SMB traffic, not just stop showing it:
    // the read holds a connection the next thing to play will want.
    final url = await proxy.registerKnownSession(smb, 'movie.mp4', chunk * 4);
    smb.afterFirstRead = () => proxy.invalidateToken(url.split('/').last);

    try {
      await fetch(url);
    } on HttpException {
      // The proxy stops short of the content-length it promised, so the
      // client sees the connection close early. That it is ugly is the point
      // being pinned: what matters is that the reading stopped.
    }

    expect(smb.reads.length, 1);
  });
}

/// Answers reads without an SMB server, from a file that does not exist.
class _FakeSmb extends SmbSource {
  final reads = <(int, int)>[];
  void Function()? afterFirstRead;

  _FakeSmb()
      : super(
          config: const ServerConfig(
            id: 'test',
            name: 'test',
            type: ImageSourceType.smb,
            host: 'localhost',
          ),
          password: '',
        );

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads.add((offset, length));
    if (reads.length == 1) afterFirstRead?.call();
    return Uint8List.fromList(
        List.generate(length, (i) => (offset + i) % 251));
  }
}
