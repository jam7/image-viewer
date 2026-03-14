import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../services/pixiv/pixiv_web_client.dart';

/// Pixiv ログイン画面。WebView2でpixiv.netにログインする。
class PixivLoginScreen extends StatefulWidget {
  final PixivWebClient webClient;
  final VoidCallback onLoginSuccess;

  const PixivLoginScreen({
    super.key,
    required this.webClient,
    required this.onLoginSuccess,
  });

  @override
  State<PixivLoginScreen> createState() => _PixivLoginScreenState();
}

class _PixivLoginScreenState extends State<PixivLoginScreen> {
  final _controller = WebviewController();
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    await _controller.initialize();

    _controller.url.listen((url) async {
      // ログインページから離れたらログイン成功と判定
      if (url.contains('pixiv.net') &&
          !url.contains('accounts.pixiv.net/login')) {
        // WebView2はユーザーデータフォルダを共有するため、
        // このWebViewでのログインCookieはPixivWebClientのWebView2でも使える
        // 念のためWebClientで再確認
        await Future.delayed(const Duration(seconds: 1));
        final loggedIn = await widget.webClient.checkLoginStatus();
        if (loggedIn) {
          widget.onLoginSuccess();
        }
      }
    });

    await _controller.loadUrl('https://accounts.pixiv.net/login');

    if (mounted) {
      setState(() => _isInitialized = true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pixiv ログイン')),
      body: _isInitialized
          ? Webview(_controller)
          : const Center(child: Text('読み込み中...')),
    );
  }
}
