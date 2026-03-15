import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

void _log(String message) {
  print('[PixivWebClient] $message');
}

/// WebViewを使ってPixiv Web APIにアクセスするクライアント。
/// 非表示の WebView で pixiv.net を読み込み、fetch() で API を呼び出す。
/// Cookie は WKWebView / WebView2 のデフォルトストアで共有されるため、
/// 別の WebView（ログイン画面）でログインすれば自動的にログイン済みになる。
class PixivWebClient {
  WebViewController? _controller;
  Future<void>? _readyFuture;
  bool _isReady = false;
  int _requestId = 0;

  /// WebView を作成し pixiv.net を読み込む。
  /// ログイン画面と並行して呼ばれる想定。
  Future<void> initialize() {
    _readyFuture ??= _doInitialize();
    return _readyFuture!;
  }

  Future<void> _doInitialize() async {
    _log('Initializing WebView...');
    final completer = Completer<void>();

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            _log('Page finished: $url');
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.pixiv.net/'));

    _controller = controller;

    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => _log('Page load timeout, continuing anyway'),
    );

    _isReady = true;
    _log('WebView ready');
  }

  /// 初期化完了を待ってからfetch()でAPIを呼び出し、JSONを返す。
  Future<Map<String, dynamic>> fetchJson(String url) async {
    if (_readyFuture != null) {
      await _readyFuture;
    }
    if (!_isReady || _controller == null) {
      throw Exception('PixivWebClient が初期化されていません');
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

    await _controller!.runJavaScript(js);

    // ポーリングで結果を待つ（最大10秒）
    for (var i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final check = await _controller!.runJavaScriptReturningResult("window['$reqId']");
      final checkStr = check.toString();
      if (checkStr != 'null' && checkStr != '<null>' && checkStr.isNotEmpty) {
        await _controller!.runJavaScript("delete window['$reqId'];");

        String jsonStr = checkStr;
        // WebView は文字列をクォートで囲んで返すことがある
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

    throw Exception('Pixiv API timeout: $url');
  }

  String? _userId;
  String? get userId => _userId;

  /// ログイン状態を確認し、ユーザーIDを取得。
  Future<bool> checkLoginStatus() async {
    try {
      _log('Checking login status...');

      if (!_isReady || _controller == null) {
        _log('WebView not ready yet');
        return false;
      }

      final data = await fetchJson('https://www.pixiv.net/ajax/user/extra');
      _log('Login check result: error=${data['error']}');
      if (data['error'] == true) return false;

      if (_userId == null) {
        final jsGetUserId =
          "(function() {"
          "  var s = document.documentElement.innerHTML;"
          "  var m = s.match(/user_id[\"']?\\s*[:=]\\s*[\"'](\\d+)[\"']/);"
          "  if (m) return m[1];"
          "  m = s.match(/userId[\"']?\\s*[:=]\\s*[\"'](\\d+)[\"']/);"
          "  if (m) return m[1];"
          "  m = s.match(/\\\"userId\\\":\\\"(\\d+)\\\"/);"
          "  if (m) return m[1];"
          "  return '';"
          "})()";

        final result = await _controller!.runJavaScriptReturningResult(jsGetUserId);
        var id = result.toString().replaceAll('"', '').replaceAll("'", '');
        _log('User ID from page HTML: "$id"');

        if (id.isNotEmpty && id != 'null') {
          _userId = id;
          _log('User ID: $_userId');
        } else {
          _log('Could not detect user ID');
        }
      }

      return true;
    } catch (e) {
      _log('Login check exception: $e');
      return false;
    }
  }

  void dispose() {
    // WebViewController has no dispose method
  }
}
