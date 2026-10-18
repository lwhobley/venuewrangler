// Thin MethodChannel bridge to Apple's DeviceCheck App Attest API. There is no Flutter plugin
// for this maintained widely enough to trust for a security-sensitive attestation path, and the
// native surface needed is small (generate a key once, attest it once), so this is hand-rolled
// rather than pulling in an unaudited third-party dependency — same call this codebase already
// made for the server-side verification (see supabase/functions/_shared/app-attest.ts's header
// comment on hand-rolling DER/CBOR rather than trusting an unaudited library for this).
//
// Dart side: lib/core/security/app_attest_service.dart. Method contract:
//   - "isSupported" -> bool
//   - "generateKey" -> String (the key identifier, base64 SHA-256 of the public key)
//   - "generateAssertion" (args: {"keyId": String, "clientDataBytes": FlutterStandardTypedData}) ->
//     the raw assertion object bytes. clientDataBytes is the exact punch payload the server will
//     hash; SHA-256 is computed here, same as for attestKey.
//   - "attestKey" (args: {"keyId": String, "nonceBytes": FlutterStandardTypedData}) -> the raw
//     attestation object bytes. clientDataHash (SHA256 of nonceBytes) is computed here, not in
//     Dart, so Dart never needs its own SHA-256 implementation just for this one call.
import Flutter
import DeviceCheck
import CryptoKit

public class AppAttestPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.venuewrangler.app/app_attest",
      binaryMessenger: registrar.messenger()
    )
    let instance = AppAttestPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result rawResult: @escaping FlutterResult) {
    // DCAppAttestService completion handlers run on a background queue, and FlutterResult must
    // only be invoked on the main thread. Every reply below goes through this wrapper.
    let result: FlutterResult = { value in
      if Thread.isMainThread {
        rawResult(value)
      } else {
        DispatchQueue.main.async { rawResult(value) }
      }
    }
    switch call.method {
    case "isSupported":
      if #available(iOS 14.0, *) {
        result(DCAppAttestService.shared.isSupported)
      } else {
        result(false)
      }

    case "generateKey":
      guard #available(iOS 14.0, *) else {
        result(FlutterError(code: "unsupported", message: "App Attest requires iOS 14+", details: nil))
        return
      }
      DCAppAttestService.shared.generateKey { keyId, error in
        if let error = error {
          result(FlutterError(code: "generate_key_failed", message: error.localizedDescription, details: nil))
          return
        }
        result(keyId)
      }

    case "attestKey":
      guard #available(iOS 14.0, *) else {
        result(FlutterError(code: "unsupported", message: "App Attest requires iOS 14+", details: nil))
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let keyId = args["keyId"] as? String,
        let nonceBytes = args["nonceBytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "invalid_arguments", message: "keyId and nonceBytes are required", details: nil))
        return
      }

      // Apple's attestKey expects a pre-hashed clientDataHash, not raw challenge bytes — it
      // does not hash the input itself. This must be exactly SHA256(nonce), matching the
      // server's own `clientDataHash = sha256(challenge)` step in app-attest.ts, or the
      // nonce-extension check on the leaf certificate will never match.
      let clientDataHash = Data(SHA256.hash(data: nonceBytes.data))

      DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) { attestationObject, error in
        if let error = error {
          result(FlutterError(code: "attest_key_failed", message: error.localizedDescription, details: nil))
          return
        }
        guard let attestationObject = attestationObject else {
          result(FlutterError(code: "attest_key_failed", message: "No attestation object returned", details: nil))
          return
        }
        result(FlutterStandardTypedData(bytes: attestationObject))
      }

    case "generateAssertion":
      guard #available(iOS 14.0, *) else {
        result(FlutterError(code: "unsupported", message: "App Attest requires iOS 14+", details: nil))
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let keyId = args["keyId"] as? String,
        let clientData = args["clientDataBytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "invalid_arguments", message: "keyId and clientDataBytes are required", details: nil))
        return
      }

      // Like attestKey, generateAssertion expects a pre-hashed clientDataHash. The server computes
      // SHA256(payload_json) and verifies the assertion against exactly that value.
      let assertionClientDataHash = Data(SHA256.hash(data: clientData.data))

      DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: assertionClientDataHash) { assertion, error in
        if let error = error {
          result(FlutterError(code: "generate_assertion_failed", message: error.localizedDescription, details: nil))
          return
        }
        guard let assertion = assertion else {
          result(FlutterError(code: "generate_assertion_failed", message: "No assertion returned", details: nil))
          return
        }
        result(FlutterStandardTypedData(bytes: assertion))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
