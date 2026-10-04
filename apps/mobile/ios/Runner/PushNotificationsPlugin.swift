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
//
// Also the app's UNUserNotificationCenterDelegate, for two things iOS otherwise does badly:
// without one, a push delivered while the app is foregrounded shows no banner at all (the
// default behavior absent a delegate); and a tap on a notification — whether the app was
// foregrounded, backgrounded, or not running at all — has nowhere to carry the notification's
// `kind`/custom data to Dart for `notification_routing.dart` to act on. `didReceive response`
// fires for all three of those cases uniformly, so this is the one place that needs to handle
// it, rather than also threading `didFinishLaunchingWithOptions`'s remote-notification key.
import Flutter
import UIKit
import UserNotifications

public class PushNotificationsPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  static var shared: PushNotificationsPlugin?

  private var pendingTokenResult: FlutterResult?
  private var channel: FlutterMethodChannel?
  // A tap that arrived before Dart had a chance to register its handler — most notably, the
  // tap that cold-launched the app. Consumed exactly once via "consumePendingNotificationTap".
  private var pendingTappedPayload: [String: Any]?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.venuewrangler.app/push_notifications",
      binaryMessenger: registrar.messenger()
    )
    let instance = PushNotificationsPlugin()
    instance.channel = channel
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
    UNUserNotificationCenter.current().delegate = instance
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

    case "consumePendingNotificationTap":
      result(pendingTappedPayload)
      pendingTappedPayload = nil

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Lets a push show its banner/sound while the app is in the foreground — iOS suppresses it
  // entirely otherwise, with no delegate set at all to opt in.
  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }

  // Fires once the user taps the notification (banner, lock screen, or notification center),
  // regardless of whether that tap foregrounded an already-running app, resumed a backgrounded
  // one, or cold-launched it. The payload carries `kind` and whatever custom `data` fields
  // notifications-send attached — routed on the Dart side by notification_routing.dart.
  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let payload = response.notification.request.content.userInfo as? [String: Any] ?? [:]
    pendingTappedPayload = payload
    // Harmless no-op if Dart hasn't registered a handler yet (e.g. a cold launch still
    // bootstrapping) — that case is covered by "consumePendingNotificationTap" instead.
    channel?.invokeMethod("onNotificationTapped", arguments: payload)
    completionHandler()
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
