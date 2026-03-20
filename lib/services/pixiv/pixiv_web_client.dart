import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;

void _log(String message) {
  print('[PixivWebClient] $message');
}

/// WebViewを使ってPixiv Web APIにアクセスするクライアント。
/// 非表示の WebView で pixiv.net を読み込み、fetch() で API を呼び出す。
/// Cookie は WKWebView / WebView2 のデフォルトストアで共有されるため、
/// 別の WebView（ログイン画面）でログインすれば自動的にログイン済みになる。
class PixivWebClient {
  // Windows
  win.WebviewController? _winController;
  // iOS / Android
  mobile.WebViewController? _mobileController;

  Future<void>? _readyFuture;
  bool _isReady = false;
  bool get isReady => _isReady;
  int _requestId = 0;

  /// WebView を作成し pixiv.net を読み込む。
  Future<void> initialize() {
    _readyFuture ??= _doInitialize();
    return _readyFuture!;
  }

  Future<void> _doInitialize() async {
    _log('Initializing WebView...');

    if (Platform.isWindows) {
      await _initWindows();
    } else {
      await _initMobile();
    }

    _isReady = true;
    _log('WebView ready');
  }

  Future<void> _initWindows() async {
    final controller = win.WebviewController();
    await controller.initialize();
    await controller.loadUrl('https://www.pixiv.net/');
    await Future.delayed(const Duration(seconds: 3));
    _winController = controller;
  }

  Future<void> _initMobile() async {
    final completer = Completer<void>();

    final controller = mobile.WebViewController()
      ..setJavaScriptMode(mobile.JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        mobile.NavigationDelegate(
          onPageFinished: (url) {
            _log('Page finished: $url');
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.pixiv.net/'));

    _mobileController = controller;

    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => _log('Page load timeout, continuing anyway'),
    );
  }

  /// fetch()でAPIを呼び出し、JSONを返す。
  Future<Map<String, dynamic>> fetchJson(String url) async {
    if (_readyFuture != null) {
      await _readyFuture;
    }
    if (!_isReady) {
      throw Exception('PixivWebClient が初期化されていません');
    }

    _log('fetchJson: $url (isReady=$_isReady, hasFuture=${_readyFuture != null})');
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
    _log('fetchJson: script executed, polling for result ($reqId)');

    // ポーリングで結果を待つ（最大10秒）
    for (var i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final check = await _evaluateScript("window['$reqId']");
      final checkStr = check.toString();
      if (i == 10 || i == 50) {
        _log('fetchJson: polling $reqId, attempt=$i, value=${checkStr.substring(0, checkStr.length > 50 ? 50 : checkStr.length)}');
      }
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

    // Log current page URL to diagnose if WebView navigated away
    try {
      final currentUrl = await _evaluateScript("window.location.href");
      _log('fetchJson TIMEOUT: $url (current page: $currentUrl)');
    } catch (_) {}
    throw Exception('Pixiv API timeout: $url');
  }

  String? _userId;
  String? get userId => _userId;
  set userId(String? id) => _userId = id;

  /// userId が取得できるまで待機。既にあれば即返却。
  /// initialize() 完了を待ち、checkLoginStatus() でリトライする。
  Future<String> waitForUserId() async {
    if (_userId != null) return _userId!;

    // WebView の準備を待つ
    await initialize();

    for (var i = 0; i < 5; i++) {
      await checkLoginStatus();
      if (_userId != null) {
        _log('waitForUserId: acquired $_userId (attempt ${i + 1})');
        return _userId!;
      }
      _log('waitForUserId: retrying in 2s... (attempt ${i + 1})');
      await Future.delayed(const Duration(seconds: 2));
    }

    throw Exception('userId を取得できませんでした');
  }

  /// ログイン状態を確認し、ユーザーIDを取得。
  Future<bool> checkLoginStatus() async {
    try {
      _log('Checking login status...');

      if (!_isReady) {
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

        final result = await _evaluateScript(jsGetUserId);
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
    } catch (e, st) {
      print('[PixivWebClient] Login check exception: $e\n$st');
      return false;
    }
  }

  /// プラットフォーム別: スクリプト実行（戻り値なし）
  Future<void> _executeScript(String js) async {
    if (Platform.isWindows && _winController != null) {
      await _winController!.executeScript(js);
    } else if (_mobileController != null) {
      await _mobileController!.runJavaScript(js);
    }
  }

  /// プラットフォーム別: スクリプト実行（戻り値あり）
  Future<String> _evaluateScript(String js) async {
    if (Platform.isWindows && _winController != null) {
      final result = await _winController!.executeScript(js);
      return result?.toString() ?? 'null';
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
