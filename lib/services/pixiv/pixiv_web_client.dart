import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;

void _log(String msg) => print('[PixivWebClient] $msg');

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

  /// Create the WebView controller (no page load).
  /// Call loadPixivPage() after login to load pixiv.net.
  Future<void> initialize() {
    _readyFuture ??= _doInitialize();
    return _readyFuture!;
  }

  Future<void> _doInitialize() async {
    _log('Initializing WebView...');
    if (Platform.isWindows) {
      final controller = win.WebviewController();
      await controller.initialize();
      _winController = controller;
    } else {
      final controller = mobile.WebViewController()
        ..setJavaScriptMode(mobile.JavaScriptMode.unrestricted);
      _mobileController = controller;
    }
    _log('WebView controller created');
  }

  /// Load pixiv.net in the API WebView and wait for completion.
  /// Call after login is confirmed (cookies must be valid).
  Future<void> loadPixivPage() async {
    await initialize();
    _log('Loading pixiv.net...');
    if (Platform.isWindows && _winController != null) {
      await _loadPageWindows('https://www.pixiv.net/');
    } else if (_mobileController != null) {
      await _loadPageMobile('https://www.pixiv.net/');
    }
    _isReady = true;
    _log('pixiv.net loaded, ready for API calls');
  }

  Future<void> _loadPageWindows(String url) async {
    final completer = Completer<void>();
    late final StreamSubscription sub;
    sub = _winController!.loadingState.listen((state) {
      if (state == win.LoadingState.navigationCompleted) {
        _log('Page load complete: $url');
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });
    await _winController!.loadUrl(url);
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _log('Page load timeout: $url');
        sub.cancel();
      },
    );
  }

  Future<void> _loadPageMobile(String url) async {
    final completer = Completer<void>();
    _mobileController!.setNavigationDelegate(
      mobile.NavigationDelegate(
        onPageFinished: (finishedUrl) {
          _log('Page load complete: $finishedUrl');
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    await _mobileController!.loadRequest(Uri.parse(url));
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => _log('Page load timeout: $url'),
    );
  }

  /// fetch()でAPIを呼び出し、JSONを返す。
  Future<Map<String, dynamic>> fetchJson(String url) async {
    if (!_isReady) {
      throw Exception('PixivWebClient: pixiv.net not loaded. Call loadPixivPage() first.');
    }

    _log('fetchJson: $url');
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

    await _executeScript(js);

    // ポーリングで結果を待つ（最大10秒）
    for (var i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final check = await _evaluateScript("window['$reqId']");
      final checkStr = check.toString();
      if (checkStr != 'null' && checkStr != '<null>' && checkStr.isNotEmpty) {
        await _executeScript("delete window['$reqId'];");

        String jsonStr = checkStr;
        if (jsonStr.startsWith('"') && jsonStr.endsWith('"')) {
          jsonStr = jsonStr.substring(1, jsonStr.length - 1);
          jsonStr = jsonStr.replaceAll(r'\"', '"');
          jsonStr = jsonStr.replaceAll(r'\\', r'\');
        }

        _log('Result (first 300): ${jsonStr.substring(0, jsonStr.length > 300 ? 300 : jsonStr.length)}');

        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
        _log('error: ${decoded['error']}, message: ${decoded['message']}');
        return decoded;
      }
    }

    try {
      final currentUrl = await _evaluateScript("window.location.href");
      _log('fetchJson TIMEOUT: $url (current page: $currentUrl)');
    } catch (_) {}
    throw Exception('Pixiv API timeout: $url');
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
