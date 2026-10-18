import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/storage/app_secure_storage.dart';
import 'package:venuewrangler_mobile/core/storage/secure_local_storage.dart';
import 'package:venuewrangler_mobile/core/storage/secure_session_storage.dart';

const _legacy = 'unlocked';
const _current = 'first_unlock_this_device';

/// Models the iOS keychain behaviour that matters here: a read/contains/readAll filters on the
/// accessibility attribute, an add for an account that already exists (under any accessibility)
/// is a duplicate error, and delete removes the item whatever its accessibility.
class _FakeKeychain extends FlutterSecureStoragePlatform {
  final Map<String, ({String value, String accessibility})> items = {};

  String _accessibility(Map<String, String> options) =>
      options['accessibility'] ?? _legacy;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    final item = items[key];
    return item != null && item.accessibility == _accessibility(options)
        ? item.value
        : null;
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      await read(key: key, options: options) != null;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    final accessibility = _accessibility(options);
    final existing = items[key];
    if (existing != null && existing.accessibility != accessibility) {
      throw PlatformException(code: '-25299', message: 'duplicate item');
    }
    items[key] = (value: value, accessibility: accessibility);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    items.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      {
        for (final e in items.entries)
          if (e.value.accessibility == _accessibility(options))
            e.key: e.value.value,
      };

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      items.clear();
}

class _FakeMarker implements InstallMarker {
  _FakeMarker({this.present = false, this.failCreate = false});

  bool present;
  final bool failCreate;

  @override
  Future<bool> exists() async => present;

  @override
  Future<void> create() async {
    if (failCreate) throw const FileSystemExceptionStandIn();
    present = true;
  }
}

class FileSystemExceptionStandIn implements Exception {
  const FileSystemExceptionStandIn();
}

void main() {
  late _FakeKeychain keychain;

  setUp(() {
    keychain = _FakeKeychain();
    FlutterSecureStoragePlatform.instance = keychain;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  void seedLegacy(Map<String, String> values) {
    for (final e in values.entries) {
      keychain.items[e.key] = (value: e.value, accessibility: _legacy);
    }
  }

  group('AppSecureStorage accessibility', () {
    test('new items are written first_unlock_this_device', () async {
      await const AppSecureStorage().write(key: 'k', value: 'v');

      expect(keychain.items['k']!.accessibility, _current);
    });

    test('options request the this-device-only accessibility', () {
      expect(kAppIOSOptions.params['accessibility'], _current);
      expect(kAppMacOsOptions.params['accessibility'], _current);
    });
  });

  group('upgrade from an older build (items stored as WhenUnlocked)', () {
    test('a legacy item is still readable and moves to the new accessibility',
        () async {
      seedLegacy({'k': 'old-value'});
      const storage = AppSecureStorage();

      expect(await storage.read(key: 'k'), 'old-value');
      expect(keychain.items['k']!.accessibility, _current);
      // And keeps reading after the move.
      expect(await storage.read(key: 'k'), 'old-value');
    });

    test('the persisted Supabase session survives the update', () async {
      seedLegacy({'supabase_persist_session': 'session-json'});
      final storage = SecureLocalStorage(firstRunWipe: () async => false);

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), 'session-json');
    });

    test('writing over an unmigrated legacy item replaces it', () async {
      seedLegacy({'k': 'old'});

      await const AppSecureStorage().write(key: 'k', value: 'new');

      expect(keychain.items['k']!.value, 'new');
      expect(keychain.items['k']!.accessibility, _current);
    });

    test('containsKey and readAll see legacy items', () async {
      seedLegacy({'a': '1'});
      await const AppSecureStorage().write(key: 'b', value: '2');
      const storage = AppSecureStorage();

      expect(await storage.containsKey(key: 'a'), isTrue);
      expect(await storage.readAll(), {'a': '1', 'b': '2'});
    });

    test('delete and deleteAll remove legacy items too', () async {
      seedLegacy({'a': '1', 'b': '2'});
      const storage = AppSecureStorage();

      await storage.delete(key: 'a');
      expect(keychain.items.containsKey('a'), isFalse);

      await storage.deleteAll();
      expect(keychain.items, isEmpty);
    });

    test('sign-out cleanup keeps device keys that were stored the old way',
        () async {
      seedLegacy({
        'theme_mode': 'dark',
        'supabase_persist_session': 'session-json',
      });

      await const SecureSessionStorage().clearAll();

      expect(keychain.items.keys, ['theme_mode']);
      expect(await const SecureSessionStorage().read('theme_mode'), 'dark');
    });
  });

  group('first-run wipe', () {
    Future<bool> wipe(_FakeMarker marker, {bool apple = true}) =>
        wipeKeychainOnFirstInstallRun(
          marker: marker,
          isApplePlatform: () => apple,
        );

    test('a reinstall (no marker, keychain left behind) is cleared', () async {
      keychain.items['supabase_persist_session'] =
          (value: 'stale-session', accessibility: _current);
      final marker = _FakeMarker();

      expect(await wipe(marker), isTrue);

      expect(keychain.items, isEmpty);
      expect(marker.present, isTrue);
    });

    test('an update over an older build is not signed out', () async {
      seedLegacy({'supabase_persist_session': 'session-json'});
      final marker = _FakeMarker();

      expect(await wipe(marker), isFalse);

      expect(
        await const AppSecureStorage().read(key: 'supabase_persist_session'),
        'session-json',
      );
      expect(marker.present, isTrue);
    });

    test('later launches never wipe', () async {
      keychain.items['k'] = (value: 'v', accessibility: _current);

      expect(await wipe(_FakeMarker(present: true)), isFalse);

      expect(keychain.items, isNotEmpty);
    });

    test('a marker that cannot be written disables the wipe', () async {
      keychain.items['k'] = (value: 'v', accessibility: _current);

      expect(await wipe(_FakeMarker(failCreate: true)), isFalse);

      expect(keychain.items, isNotEmpty);
    });

    test('Android only records the marker', () async {
      keychain.items['k'] = (value: 'v', accessibility: _current);
      final marker = _FakeMarker();

      expect(await wipe(marker, apple: false), isFalse);

      expect(keychain.items, isNotEmpty);
      expect(marker.present, isTrue);
    });

    test('SecureLocalStorage runs the wipe before the session is read',
        () async {
      var wiped = 0;
      final storage = SecureLocalStorage(
        firstRunWipe: () async {
          wiped++;
          return false;
        },
      );

      await storage.initialize();

      expect(wiped, 1);
    });
  });

  test('FlutterSecureStorage type is preserved for existing call sites', () {
    expect(const AppSecureStorage(), isA<FlutterSecureStorage>());
  });
}
