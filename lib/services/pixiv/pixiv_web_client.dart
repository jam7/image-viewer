import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:logging/logging.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;

final _log = Logger('PixivWebClient');

/// Pixiv API呼び出し用の非表示WebView。
/// fetch() でAPIを呼び、結果をJSONで返す。Cookie共有でログイン済みを前提とする。
class PixivWebClient {
  // Windows
  win.WebviewController? _winController;

  // iOS / Android
  mobile.WebViewController? _mobileController;

  Future<void>? _readyFuture;
  bool _isReady = false;
  bool get isReady => _isReady;
  int _requestId = 0;
  String? _csrfToken;
  set csrfToken(String token) => _csrfToken = token;

  /// Create the WebView controller (no page load).
  /// Call loadPixivPage() after login to load pixiv.net.
  Future<void> initialize() {
    _readyFuture ??= _doInitialize();
    return _readyFuture!;
  }

  Future<void> _doInitialize() async {
    _log.info('Initializing WebView...');
    try {
      if (Platform.isWindows) {
        final controller = win.WebviewController();
        await controller.initialize();
        _winController = controller;
      } else {
        final controller = mobile.WebViewController()
          ..setJavaScriptMode(mobile.JavaScriptMode.unrestricted);
        _mobileController = controller;
      }
      _log.info('WebView controller created');
    } catch (e, st) {
      // Clear cached future so next initialize() call retries
      _readyFuture = null;
      _log.severe('WebView initialization failed', e, st);
      rethrow;
    }
  }

  /// Load pixiv.net in the API WebView and wait for completion.
  /// Call after login is confirmed (cookies must be valid).
  Future<void> loadPixivPage() async {
    await initialize();
    _log.info('Loading pixiv.net...');
    if (Platform.isWindows && _winController != null) {
      await _loadPageWindows('https://www.pixiv.net/');
    } else if (_mobileController != null) {
      await _loadPageMobile('https://www.pixiv.net/');
    }
    _isReady = true;
    _log.info('pixiv.net loaded, ready for API calls');
  }

  Future<void> _loadPageWindows(String url) async {
    final completer = Completer<void>();
    late final StreamSubscription sub;
    sub = _winController!.loadingState.listen((state) {
      _log.info('loadingState: $state (waiting for navigationCompleted)');
      if (state == win.LoadingState.navigationCompleted) {
        _log.info('Page load complete: $url');
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });
    await _winController!.loadUrl(url);
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _log.warning('Page load timeout: $url');
        sub.cancel();
      },
    );
  }

  Future<void> _loadPageMobile(String url) async {
    final completer = Completer<void>();
    _mobileController!.setNavigationDelegate(
      mobile.NavigationDelegate(
        onPageFinished: (finishedUrl) {
          _log.info('Page load complete: $finishedUrl');
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    await _mobileController!.loadRequest(Uri.parse(url));
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => _log.warning('Page load timeout: $url'),
    );
  }

  /// Execute a fetch() in the WebView and poll for the JSON result.
  Future<Map<String, dynamic>> _fetchViaWebView(String fetchJs, String reqId, String label) async {
    await _executeScript(fetchJs);

    // Poll for result (max 10 seconds)
    for (var i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final check = await _evaluateScript("window['$reqId']");
      final checkStr = check.toString();
      if (checkStr != 'null' && checkStr != '<null>' && checkStr.isNotEmpty) {
        await _executeScript("delete window['$reqId'];");

        // WebView's evaluateScript wraps JSON strings in extra quotes.
        // Double jsonDecode separates the outer unescaping from JSON parsing.
        String jsonStr = checkStr;
        if (jsonStr.startsWith('"') && jsonStr.endsWith('"')) {
          jsonStr = jsonDecode(jsonStr) as String;
        }

        _log.info('$label result (first 300): ${jsonStr.substring(0, jsonStr.length > 300 ? 300 : jsonStr.length)}');

        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
        _log.info('error: ${decoded['error']}, message: ${decoded['message']}');
        return decoded;
      }
    }

    // Clean up the window property to prevent memory leak
    await _executeScript("delete window['$reqId'];");
    throw Exception('Pixiv $label timeout');
  }

  /// GET request via fetch().
  Future<Map<String, dynamic>> fetchJson(String url) async {
    if (!_isReady) {
      throw Exception('PixivWebClient: pixiv.net not loaded. Call loadPixivPage() first.');
    }

    _log.info('fetchJson: $url');
    final reqId = '_pixiv_result_${_requestId++}';

    final js = '''
      window['$reqId'] = null;
      fetch('$url', {
        credentials: 'include',
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      })
      .then(r => r.text())
      .then(t => { window['$reqId'] = t; })
      .catch(e => { window['$reqId'] = JSON.stringify({error: true, message: e.toString()}); });
    ''';

    return _fetchViaWebView(js, reqId, 'fetchJson');
  }

  /// POST request with JSON body via fetch(). Requires CSRF token.
  Future<Map<String, dynamic>> postJson(
    String url,
    Map<String, dynamic> body,
  ) async {
    if (!_isReady) {
      throw Exception('PixivWebClient: pixiv.net not loaded. Call loadPixivPage() first.');
    }
    if (_csrfToken == null) {
      throw Exception('PixivWebClient: CSRF token not available.');
    }

    _log.info('postJson: $url body=$body');
    final reqId = '_pixiv_result_${_requestId++}';
    final bodyJson = jsonEncode(body).replaceAll("'", "\\'");

    final js = '''
      window['$reqId'] = null;
      fetch('$url', {
        method: 'POST',
        credentials: 'include',
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-Requested-With': 'XMLHttpRequest',
          'x-csrf-token': '$_csrfToken'
        },
        body: '$bodyJson'
      })
      .then(r => r.text())
      .then(t => { window['$reqId'] = t; })
      .catch(e => { window['$reqId'] = JSON.stringify({error: true, message: e.toString()}); });
    ''';

    return _fetchViaWebView(js, reqId, 'postJson');
  }

  String? _userId;
  String? get userId => _userId;
  set userId(String? id) => _userId = id;

  Future<void> _executeScript(String js) async {
    if (Platform.isWindows && _winController != null) {
      await _winController!.executeScript(js);
    } else if (_mobileController != null) {
      await _mobileController!.runJavaScript(js);
    }
  }

  Future<dynamic> _evaluateScript(String js) async {
    if (Platform.isWindows && _winController != null) {
      return await _winController!.executeScript(js);
    } else if (_mobileController != null) {
      final result = await _mobileController!.runJavaScriptReturningResult(js);
      return result.toString();
    }
    return 'null';
  }

  void dispose() {
    _winController?.dispose();
  }
}
