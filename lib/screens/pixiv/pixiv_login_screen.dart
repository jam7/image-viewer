import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;

final _log = Logger('PixivLogin');

/// Pixiv ログイン画面。Windows は WebView2、iOS/Android は WKWebView/Android WebView。
/// ログイン専用。API 呼び出しには PixivWebClient の別 WebView を使う。
///
/// Cookie が有効な場合: accounts.pixiv.net/login → 即リダイレクト → www.pixiv.net
/// に到達 → pop。WebView は見せずにローディング表示のみ。
///
/// Cookie が無効な場合: accounts.pixiv.net/login にとどまる → WebView を表示して
/// ユーザーがログイン → www.pixiv.net に到達 → pop。
class PixivLoginScreen extends StatefulWidget {
  final void Function({String? userId}) onLoginSuccess;

  const PixivLoginScreen({
    super.key,
    required this.onLoginSuccess,
  });

  @override
  State<PixivLoginScreen> createState() => _PixivLoginScreenState();
}

class _PixivLoginScreenState extends State<PixivLoginScreen> {
  // Windows
  win.WebviewController? _winController;

  // iOS / Android
  mobile.WebViewController? _mobileController;

  bool _isInitialized = false;
  bool _loginHandled = false;
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

    controller.url.listen((url) => _onUrlChanged(url));
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

  /// Extract userId then pop. Ensures userId is set before pop returns.
  Future<void> _completeLogin() async {
    await _extractUserIdAsync();
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
    } catch (e, st) {
      _log.warning('Error extracting user ID', e, st);
    }
  }

  @override
  void dispose() {
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
