import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;

import '../../services/pixiv/pixiv_web_client.dart';

final _log = Logger('PixivLogin');

/// Pixiv ログイン画面。Windows は WebView2、iOS/Android は WKWebView/Android WebView。
/// ログイン専用。API 呼び出しには PixivWebClient の別 WebView を使う。
///
/// Cookie が有効な場合: accounts.pixiv.net/login → 即リダイレクト → www.pixiv.net
/// に到達 → API WebView ロード → pop。WebView は見せずにローディング表示のみ。
///
/// Cookie が無効な場合: accounts.pixiv.net/login にとどまる → WebView を表示して
/// ユーザーがログイン → www.pixiv.net に到達 → API WebView ロード → pop。
class PixivLoginScreen extends StatefulWidget {
  final void Function({String? userId}) onLoginSuccess;
  final PixivWebClient webClient;

  const PixivLoginScreen({
    super.key,
    required this.onLoginSuccess,
    required this.webClient,
  });

  @override
  State<PixivLoginScreen> createState() => _PixivLoginScreenState();
}

class _PixivLoginScreenState extends State<PixivLoginScreen> {
  // Windows
  win.WebviewController? _winController;
  StreamSubscription<String>? _urlSubscription;

  // iOS / Android
  mobile.WebViewController? _mobileController;

  bool _isInitialized = false;
  bool _loginHandled = false;
  Completer<void>? _pageFinishCompleter;
  // Cookie 有効で即リダイレクトされる場合は WebView を見せない。
  // accounts.pixiv.net にとどまった（= ログインが必要）場合のみ true にする。
  bool _showWebView = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    if (Platform.isWindows) {
      await _initWindows();
    } else {
      _initMobile();
    }
  }

  Future<void> _initWindows() async {
    final controller = win.WebviewController();
    await controller.initialize();

    _urlSubscription = controller.url.listen((url) => _onUrlChanged(url));
    await controller.loadUrl('https://accounts.pixiv.net/login');

    _winController = controller;
    if (mounted) setState(() => _isInitialized = true);
  }

  void _initMobile() {
    final controller = mobile.WebViewController()
      ..setJavaScriptMode(mobile.JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        mobile.NavigationDelegate(
          onUrlChange: (change) => _onUrlChanged(change.url ?? ''),
          onPageFinished: (url) {
            _log.info('Page finished: $url');
            if (_pageFinishCompleter != null && !_pageFinishCompleter!.isCompleted) {
              _pageFinishCompleter!.complete();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://accounts.pixiv.net/login'));

    _mobileController = controller;
    if (mounted) setState(() => _isInitialized = true);
  }

  void _onUrlChanged(String url) {
    if (_loginHandled) return;
    _log.info('URL: $url');

    // www.pixiv.net に到達したらログイン完了。
    if (url.startsWith('https://www.pixiv.net')) {
      _loginHandled = true;
      _log.info('Login complete, URL: $url');
      // WebView を隠してローディング表示に切り替え（pixiv ホームが見えないように）
      if (mounted) setState(() => _showWebView = false);
      _completeLogin();
      return;
    }

    // accounts.pixiv.net のログインページにとどまった = ログインが必要。
    // WebView を表示してユーザーに入力してもらう。
    if (url.contains('accounts.pixiv.net') && !_showWebView) {
      _log.info('Login required, showing WebView');
      if (mounted) setState(() => _showWebView = true);
    }
  }

  /// Extract userId, load API WebView, then pop.
  /// ホーム画面が露出しないよう、API WebView の準備完了まで
  /// ローディング表示を維持してから pop する。
  Future<void> _completeLogin() async {
    // iOS: onUrlChange はナビゲーション開始時に発火するため、
    // HTML がまだ空の状態で userId 抽出すると失敗する。
    // onPageFinished を待ってから抽出する。
    if (_mobileController != null) {
      _pageFinishCompleter = Completer<void>();
      _log.info('Waiting for page finish before extracting userId...');
      await _pageFinishCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => _log.warning('Page finish timeout, proceeding anyway'),
      );
    }
    await _extractUserIdAsync();
    try {
      _log.info('Loading API WebView before pop...');
      await widget.webClient.loadPixivPage();
      _log.info('API WebView ready');
    } catch (e, st) {
      _log.warning('Failed to load API WebView', e, st);
      // API WebView のロード失敗でもログイン自体は成功しているので pop する
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    });
  }

  Future<void> _extractUserIdAsync() async {
    try {
      final js =
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

      String id = '';
      if (Platform.isWindows && _winController != null) {
        final result = await _winController!.executeScript(js);
        id = result?.toString().replaceAll('"', '').replaceAll("'", '') ?? '';
      } else if (_mobileController != null) {
        final result = await _mobileController!.runJavaScriptReturningResult(js);
        id = result.toString().replaceAll('"', '').replaceAll("'", '');
      }

      if (id.isNotEmpty && id != 'null') {
        _log.info('User ID from login page: $id');
        widget.onLoginSuccess(userId: id);
      } else {
        _log.info('Could not extract user ID from login page');
      }

      // Extract CSRF token from the same page for bookmark API
      await _extractCsrfToken();
    } catch (e, st) {
      _log.warning('Error extracting user ID', e, st);
    }
  }

  Future<void> _extractCsrfToken() async {
    // Token is in escaped JSON in innerHTML: token\":\"hex...\"
    final tokenJs =
      "(function() {"
      "  var s = document.documentElement.innerHTML;"
      "  var m = s.match(/token\\\\\":\\\\\"([0-9a-f]+)\\\\\"/);"
      "  if (m) return m[1];"
      "  return '';"
      "})()";

    // Wait for SPA render — the token is injected by React, not in
    // the initial HTML. Retry up to 5 seconds.
    for (var i = 0; i < 50; i++) {
      try {
        String token = '';
        if (Platform.isWindows && _winController != null) {
          final result = await _winController!.executeScript(tokenJs);
          token = result?.toString().replaceAll('"', '').replaceAll("'", '') ?? '';
        } else if (_mobileController != null) {
          final result = await _mobileController!.runJavaScriptReturningResult(tokenJs);
          token = result.toString().replaceAll('"', '').replaceAll("'", '');
        }

        if (token.isNotEmpty && token != 'null') {
          _log.info('CSRF token from login page: ${token.length} chars (attempt ${i + 1})');
          widget.webClient.csrfToken = token;
          return;
        }
      } catch (e, st) {
        _log.warning('CSRF extraction error (attempt ${i + 1})', e, st);
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _log.warning('Could not extract CSRF token from login page after retries');
  }

  @override
  @override
  void dispose() {
    _urlSubscription?.cancel();
    _winController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // AppBar を見せるのはログインが必要な場合のみ
      appBar: _showWebView ? AppBar(title: const Text('Pixiv ログイン')) : null,
      backgroundColor: _showWebView ? null : Colors.white,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // ログインが必要な場合: WebView を表示
    if (_showWebView && _isInitialized) {
      return _buildWebView();
    }

    // Cookie チェック中（即リダイレクトを待っている）
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Pixiv に接続中...'),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    if (Platform.isWindows && _winController != null) {
      return win.Webview(_winController!);
    }
    if (_mobileController != null) {
      return mobile.WebViewWidget(controller: _mobileController!);
    }
    return const Center(child: Text('WebView unavailable'));
  }
}
