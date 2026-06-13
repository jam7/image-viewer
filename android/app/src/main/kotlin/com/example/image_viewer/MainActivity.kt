package com.example.image_viewer

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val cookieChannel = "pixiv/cookies"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cookieChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Returns the cookie header for the given URL from the native
                    // WebView CookieManager. Unlike document.cookie in JS, this
                    // includes httpOnly cookies (e.g. PHPSESSID).
                    "getCookie" -> {
                        val url = call.argument<String>("url") ?: "https://www.pixiv.net"
                        result.success(CookieManager.getInstance().getCookie(url))
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
