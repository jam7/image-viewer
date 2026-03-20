import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as win;

/// Pixiv ログイン画面。Windows は WebView2、iOS/Android は WKWebView/Android WebView。
/// ログイン専用。API 呼び出しには PixivWebClient の別 WebView を使う。
class PixivLoginScreen extends StatefulWidget {
  /// ログイン成功時に呼ばれる。ユーザーIDが取得できた場合は渡す。
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

    // www.pixiv.net に到達したらログイン完了。
    // accounts.pixiv.net の別ページ（reCAPTCHA、追加認証等）は
    // まだログイン完了ではないので無視する。
    if (url.startsWith('https://www.pixiv.net')) {
      _loginHandled = true;
      widget.onLoginSuccess(userId: null);
      _extractUserIdAsync();
    }
  }

  /// ログイン後のページHTMLからユーザーIDを非同期で取得
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
        print('[PixivLogin] User ID from login page: $id');
        widget.onLoginSuccess(userId: id);
      } else {
        print('[PixivLogin] Could not extract user ID from login page');
      }
    } catch (e, st) {
      print('[PixivLogin] Error extracting user ID: $e\n$st');
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
      appBar: AppBar(title: const Text('Pixiv ログイン')),
      body: _isInitialized ? _buildWebView() : const Center(child: Text('読み込み中...')),
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
