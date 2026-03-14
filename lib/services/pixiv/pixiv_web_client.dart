import 'dart:convert';
import 'dart:io' show Platform;

import 'package:webview_windows/webview_windows.dart' as win;

void _log(String message) {
  print('[PixivWebClient] $message');
}

/// WebView2を使ってPixiv Web APIにアクセスするクライアント。
/// httpOnly cookieを含む全cookieが自動送信される。
class PixivWebClient {
  win.WebviewController? _winController;
  bool _isInitialized = false;
  int _requestId = 0;

  /// WebView2を初期化。
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (Platform.isWindows) {
      _log('Initializing WebView2...');
      _winController = win.WebviewController();
      await _winController!.initialize();
      _log('Loading pixiv.net...');
      await _winController!.loadUrl('https://www.pixiv.net/');
      await Future.delayed(const Duration(seconds: 3));
      _log('WebView2 ready');
    }
    _isInitialized = true;
  }

  /// WebView内からfetch()でAPIを呼び出し、JSONを返す。
  Future<Map<String, dynamic>> fetchJson(String url) async {
    if (!_isInitialized || _winController == null) {
      throw Exception('PixivWebClient が初期化されていません');
    }

    _log('fetchJson: $url');
    final reqId = '_pixiv_result_${_requestId++}';

    // fetch結果をwindowのグローバル変数に格納するスクリプト
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

    await _winController!.executeScript(js);

    // ポーリングで結果を待つ（最大10秒）
    for (var i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final check = await _winController!.executeScript("window['$reqId']");
      final checkStr = check.toString();
      if (checkStr != 'null' && checkStr.isNotEmpty) {
        // クリーンアップ
        await _winController!.executeScript("delete window['$reqId'];");

        String jsonStr = checkStr;
        // WebView2は文字列をクォートで囲んで返す
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

  /// ログイン中のユーザーID。
  String? _userId;
  String? get userId => _userId;

  /// ログイン状態を確認し、ユーザーIDを取得。
  Future<bool> checkLoginStatus() async {
    try {
      _log('Checking login status...');
      // ページ内のメタデータからユーザーIDを取得
      if (_winController != null) {
        final result = await _winController!.executeScript(
          "document.querySelector('meta[name=\"global-data\"]')?.getAttribute('id') "
          "|| document.body?.dataset?.userId "
          "|| (document.cookie.match(/user_id=(\\d+)/) || [])[1] "
          "|| ''",
        );
        var id = result.toString().replaceAll('"', '').replaceAll("'", '');
        if (id.isEmpty) {
          // pixiv.netのグローバル変数からユーザーIDを取得
          final jsResult = await _winController!.executeScript(
            "typeof pixiv !== 'undefined' && pixiv.user ? pixiv.user.id.toString() : ''",
          );
          id = jsResult.toString().replaceAll('"', '').replaceAll("'", '');
        }
        if (id.isNotEmpty && id != 'null') {
          _userId = id;
          _log('User ID: $_userId');
        }
      }

      final data = await fetchJson('https://www.pixiv.net/ajax/user/extra');
      _log('Login check result: error=${data['error']}');
      return data['error'] != true;
    } catch (e) {
      _log('Login check exception: $e');
      return false;
    }
  }

  void dispose() {
    _winController?.dispose();
  }
}
