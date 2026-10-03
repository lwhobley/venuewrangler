// Thin MethodChannel bridge for requesting notification permission and obtaining a raw APNs
// device token natively — paired with the native APNs dispatch branch in
// supabase/functions/notifications-send/index.ts (gated on APNS_KEY/APNS_KEY_ID/APNS_TEAM_ID/
// APNS_BUNDLE_ID, all now set as live secrets). Deliberately not routed through Firebase on
// iOS: this app's iOS push path is native APNs end to end, matching those secrets directly,
// rather than registering an FCM token that would need Firebase's own bridge to deliver.
//
// UIApplicationDelegate only hands the device token (or a registration failure) to AppDelegate
// itself, asynchronously, disconnected from the Dart call that triggered registration — so this
// plugin holds a single pending FlutterResult between "requestPermissionAndRegister" being
// called and AppDelegate forwarding whichever callback fires first.
import Flutter
import UIKit
import UserNotifications

public class PushNotificationsPlugin: NSObject, FlutterPlugin {
  static var shared: PushNotificationsPlugin?

  private var pendingTokenResult: FlutterResult?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.venuewrangler.app/push_notifications",
      binaryMessenger: registrar.messenger()
    )
    let instance = PushNotificationsPlugin()
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermissionAndRegister":
      // Only one registration attempt in flight at a time — a second call before the first
      // resolves replaces the pending result rather than leaving the first Dart caller hanging
      // forever (it will just never get a response, which the Dart side should treat as a
      // timeout, not block on indefinitely).
      pendingTokenResult = result
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
        guard granted, error == nil else {
          DispatchQueue.main.async {
            self.resolvePending(.failure(code: "permission_denied", message: error?.localizedDescription ?? "Notification permission was not granted"))
          }
          return
        }
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Called from AppDelegate's didRegisterForRemoteNotificationsWithDeviceToken.
  func handleDeviceToken(_ deviceToken: Data) {
    let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
    resolvePending(.success(tokenHex))
  }

  // Called from AppDelegate's didFailToRegisterForRemoteNotificationsWithError.
  func handleRegistrationError(_ error: Error) {
    resolvePending(.failure(code: "registration_failed", message: error.localizedDescription))
  }

  private enum PendingOutcome {
    case success(String)
    case failure(code: String, message: String)
  }

  private func resolvePending(_ outcome: PendingOutcome) {
    guard let pending = pendingTokenResult else { return }
    pendingTokenResult = nil
    switch outcome {
    case .success(let token):
      pending(token)
    case .failure(let code, let message):
      pending(FlutterError(code: code, message: message, details: nil))
    }
  }
}
