import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Keychain accessibility for everything this app stores: readable after the first unlock
/// (background push handling and token refresh keep working) but never migrated to another
/// device through an iCloud/iTunes backup restore.
const IOSOptions kAppIOSOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const MacOsOptions kAppMacOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// What every item written before [kAppIOSOptions] existed was stored with (the plugin's default).
const IOSOptions _legacyIOSOptions = IOSOptions.defaultOptions;
const MacOsOptions _legacyMacOsOptions = MacOsOptions.defaultOptions;

bool _isApplePlatform() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// The one [FlutterSecureStorage] the app uses.
///
/// * iOS/macOS: items are written `first_unlock_this_device`.
/// * Android: flutter_secure_storage 10 already encrypts with AES-GCM under an RSA-OAEP-wrapped
///   Keystore key. The `encryptedSharedPreferences` option is deprecated and ignored in this
///   major version (the plugin migrates such data itself), so there is no Android option to set.
///
/// A keychain read filters on `kSecAttrAccessible`, so an item an older build wrote as
/// `WhenUnlocked` is invisible to a read that asks for the new accessibility. Switching options
/// alone would therefore sign every existing user out on update. Each operation here falls back
/// to the legacy accessibility and moves what it finds to the new one, so ordinary upgrades keep
/// their session.
class AppSecureStorage extends FlutterSecureStorage {
  const AppSecureStorage()
      : super(iOptions: kAppIOSOptions, mOptions: kAppMacOsOptions);

  static const FlutterSecureStorage _legacy = FlutterSecureStorage(
    iOptions: _legacyIOSOptions,
    mOptions: _legacyMacOsOptions,
  );

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final current = await super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (current != null || !_isApplePlatform()) return current;

    final old = await _legacy.read(key: key);
    if (old == null) return null;
    // Re-store under the new accessibility. A failure must not lose the value the caller is
    // about to use; the next read simply tries again.
    try {
      await _legacy.delete(key: key);
      await super.write(key: key, value: old);
    } catch (error) {
      debugPrint('Secure storage: legacy item migration deferred: $error');
    }
    return old;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    Future<void> attempt() => super.write(
          key: key,
          value: value,
          iOptions: iOptions,
          aOptions: aOptions,
          lOptions: lOptions,
          webOptions: webOptions,
          mOptions: mOptions,
          wOptions: wOptions,
        );
    try {
      await attempt();
    } on PlatformException {
      if (!_isApplePlatform() || value == null) rethrow;
      // A legacy item with the same account still exists (the keychain keys items without
      // regard to accessibility, so adding the new one is a duplicate). Replace it.
      await _legacy.delete(key: key);
      await attempt();
    }
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final current = await super.containsKey(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (current || !_isApplePlatform()) return current;
    return _legacy.containsKey(key: key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final current = await super.readAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (!_isApplePlatform()) return current;
    return {...await _legacy.readAll(), ...current};
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (_isApplePlatform()) await _legacy.delete(key: key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await super.deleteAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
    if (_isApplePlatform()) await _legacy.deleteAll();
  }
}

/// A flag that lives in the app's own sandbox, so it disappears when the app is uninstalled
/// while Keychain items (which survive an iOS uninstall) do not.
abstract interface class InstallMarker {
  Future<bool> exists();
  Future<void> create();
}

/// [InstallMarker] backed by a file in the application-support directory. (SharedPreferences
/// would also do, but it is not a direct dependency of this app.)
class FileInstallMarker implements InstallMarker {
  const FileInstallMarker([this.name = 'vw_installed']);

  final String name;

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/$name');

  @override
  Future<bool> exists() async => (await _file()).exists();

  @override
  Future<void> create() async {
    final file = await _file();
    await file.create(recursive: true);
  }
}

/// Keychain items outlive an iOS uninstall, so a reinstall can silently resurrect the previous
/// install's session. On the first launch of an install (no [InstallMarker]) this clears the
/// keychain, then records the marker.
///
/// It deliberately does nothing when items written by a build older than this one are present:
/// those have no marker either, and wiping them would sign out every user who merely updates the
/// app. Such an install is migrated by [AppSecureStorage] instead. Android reinstalls already
/// lose their Keystore key and data, so only iOS/macOS are wiped.
///
/// Returns true when a wipe happened. Never throws: if the marker cannot be written the wipe is
/// skipped (otherwise it would repeat, and sign the user out, on every launch).
Future<bool> wipeKeychainOnFirstInstallRun({
  FlutterSecureStorage storage = const AppSecureStorage(),
  InstallMarker marker = const FileInstallMarker(),
  bool Function()? isApplePlatform,
}) async {
  try {
    if (await marker.exists()) return false;
    await marker.create();
    if (!(isApplePlatform ?? _isApplePlatform)()) return false;

    // Legacy-accessibility items mean this is an update over an older build, not a reinstall.
    final legacyItems = await const FlutterSecureStorage(
      iOptions: _legacyIOSOptions,
      mOptions: _legacyMacOsOptions,
    ).readAll();
    if (legacyItems.isNotEmpty) return false;

    await storage.deleteAll();
    return true;
  } catch (error) {
    debugPrint('Secure storage: first-run wipe skipped: $error');
    return false;
  }
}
