package com.venuewrangler.app

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge to the Play Integrity *standard* API for per-request punch proof.
 *
 * Dart side: lib/core/security/play_integrity_service.dart. Method contract:
 *   - "requestToken" (args: {"requestHash": String, "cloudProjectNumber": String}) -> token String
 *
 * The requestHash is the lowercase hex SHA-256 of the exact punch payload; Google echoes it back
 * in the decoded verdict and the server (supabase/functions/time-clock-punch) rejects a token
 * whose hash differs, so a token cannot be replayed against another request. The token provider
 * is prepared once per process and reused (Google recommends warming it up, not per request).
 */
class PlayIntegrityBridge(private val context: Context) {
    private var provider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null
    private var providerProject: Long = 0L

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestToken" -> {
                    val requestHash = call.argument<String>("requestHash")
                    val projectNumber = call.argument<String>("cloudProjectNumber")?.toLongOrNull()
                    if (requestHash.isNullOrEmpty() || projectNumber == null) {
                        result.error("invalid_arguments", "requestHash and cloudProjectNumber are required", null)
                        return@setMethodCallHandler
                    }
                    requestToken(requestHash, projectNumber, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestToken(requestHash: String, projectNumber: Long, result: MethodChannel.Result) {
        val existing = provider
        if (existing != null && providerProject == projectNumber) {
            request(existing, requestHash, result)
            return
        }

        val manager = IntegrityManagerFactory.createStandard(context)
        manager
            .prepareIntegrityToken(
                StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
                    .setCloudProjectNumber(projectNumber)
                    .build(),
            )
            .addOnSuccessListener { prepared ->
                provider = prepared
                providerProject = projectNumber
                request(prepared, requestHash, result)
            }
            .addOnFailureListener { error ->
                result.error("prepare_failed", error.message, null)
            }
    }

    private fun request(
        tokenProvider: StandardIntegrityManager.StandardIntegrityTokenProvider,
        requestHash: String,
        result: MethodChannel.Result,
    ) {
        tokenProvider
            .request(
                StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
                    .setRequestHash(requestHash)
                    .build(),
            )
            .addOnSuccessListener { response -> result.success(response.token()) }
            .addOnFailureListener { error ->
                // A stale provider (e.g. after a Play Services update) is dropped so the next
                // request prepares a fresh one.
                provider = null
                result.error("request_failed", error.message, null)
            }
    }

    private companion object {
        const val CHANNEL = "com.venuewrangler.app/play_integrity"
    }
}
