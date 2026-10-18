package com.venuewrangler.app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Per-request Play Integrity proof for time punches (lib/core/security/play_integrity_service.dart).
        PlayIntegrityBridge(applicationContext).register(flutterEngine.dartExecutor.binaryMessenger)
        // Dart side: lib/core/privacy/screen_security.dart. FLAG_SECURE blocks screenshots and
        // screen recording and blanks the recents thumbnail while HR, pay, document or incident
        // evidence screens are visible.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_SECURITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val secure = call.argument<Boolean>("secure") ?: false
                        if (secure) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val SCREEN_SECURITY_CHANNEL = "com.venuewrangler.app/screen_security"
    }
}
