import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'pixiv_web_client.dart';

final _log = Logger('PixivTransport');

/// Transport for Pixiv `/ajax` JSON endpoints.
///
/// Two implementations, both backed by [PixivWebClient] for authentication
/// (login, cookie store, User-Agent):
/// - [WebViewJsonTransport]: runs `fetch()` inside the authenticated WebView.
/// - [DioJsonTransport]: direct HTTP via Dio, sending the session cookie pulled
///   from the native cookie store plus the WebView's User-Agent.
///
/// The Dio path avoids the WebView fetch's main-thread contention, 100ms
/// polling and large-payload JS->Dart bridge transfer, which made the first
/// content load slow on Android (see docs/pixiv_connection.md).
abstract class PixivJsonTransport {
  Future<Map<String, dynamic>> getJson(String url);
  Future<Map<String, dynamic>> postJson(String url, Map<String, dynamic> body);
  void dispose();

  /// Select the transport for the current platform. Android uses Dio (the
  /// WebView fetch is slow for large payloads there); Windows keeps the WebView
  /// fetch (already fast). iOS keeps the WebView fetch until native cookie
  /// extraction is verified on that platform.
  factory PixivJsonTransport.forPlatform(PixivWebClient webClient) {
    if (Platform.isAndroid) {
      return DioJsonTransport(webClient);
    }
    return WebViewJsonTransport(webClient);
  }
}

/// JSON transport that delegates to the WebView's `fetch()`.
class WebViewJsonTransport implements PixivJsonTransport {
  final PixivWebClient _webClient;

  WebViewJsonTransport(this._webClient);

  @override
  Future<Map<String, dynamic>> getJson(String url) => _webClient.fetchJson(url);

  @override
  Future<Map<String, dynamic>> postJson(String url, Map<String, dynamic> body) =>
      _webClient.postJson(url, body);

  @override
  void dispose() {}
}

/// JSON transport that issues direct HTTP requests with Dio, using the session
/// cookie + User-Agent obtained from the WebView. GET only — see [postJson].
class DioJsonTransport implements PixivJsonTransport {
  static const _referer = 'https://www.pixiv.net/';

  final PixivWebClient _webClient;
  // responseType.plain keeps the raw body so a Cloudflare challenge (HTML) can
  // be distinguished from JSON; validateStatus accepts all so non-2xx is logged.
  final Dio _dio = Dio(BaseOptions(
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
  ));

  DioJsonTransport(this._webClient);

  @override
  Future<Map<String, dynamic>> getJson(String url) async {
    // Read the cookie fresh on every request: Cloudflare's __cf_bm and the
    // session cookie can rotate, and getNativeCookie reads the live store.
    final cookie = await _webClient.getNativeCookie(_referer);
    final ua = _webClient.userAgent;
    final resp = await _dio.get<String>(
      url,
      options: Options(headers: {
        'Cookie': ?cookie,
        'User-Agent': ?ua,
        'Referer': _referer,
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json',
      }),
    );
    final body = resp.data ?? '';
    _log.info('GET $url -> ${resp.statusCode} (${body.length}B)');
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } on FormatException catch (e, st) {
      // A non-JSON body almost certainly means a Cloudflare challenge page.
      final snippet = body.substring(0, body.length > 200 ? 200 : body.length);
      _log.warning('Dio GET returned non-JSON (status ${resp.statusCode}) for '
          '$url (first 200): $snippet', e, st);
      throw Exception('Pixiv Dio GET returned non-JSON (status ${resp.statusCode})');
    }
  }

  // POST (bookmark add) is rare and not performance-critical, and a Dio POST
  // through Cloudflare is not yet verified. Keep it on the proven WebView path.
  @override
  Future<Map<String, dynamic>> postJson(String url, Map<String, dynamic> body) =>
      _webClient.postJson(url, body);

  @override
  void dispose() => _dio.close();
}
