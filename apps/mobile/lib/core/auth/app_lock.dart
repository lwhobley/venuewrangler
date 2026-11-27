import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show compute, kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import '../storage/secure_session_storage.dart';
import 'sign_out_service.dart';

/// App PIN ("quick unlock") for a person's own phone.
///
/// The person signs in once with email and password (and their authenticator, if they have
/// one). After that they can set a 4–6 digit PIN. The Supabase session stays on the device as
/// before; the PIN only gates the UI ([AppLockGate] in features/auth/app_lock_screen.dart):
///
/// - on a cold start when a PIN is set for the restored session's user, and
/// - when the app comes back after [kAppLockTimeout] or longer in the background.
///
/// It is a device-local convenience lock, not a server credential: the server never sees the
/// PIN and still enforces RLS and MFA on the session itself. After [kAppLockMaxFailures] wrong
/// PINs (counted across restarts) the person is signed out and must use their password again.
/// Signing out wipes the PIN with the rest of secure storage
/// ([SecureSessionStorage.clearAll]), so a PIN never carries over to another account.
///
/// Not offered on web: browser storage is not a device keychain and there is no "own phone".

/// How long the app may sit in the background before it asks for the PIN again.
const kAppLockTimeout = Duration(minutes: 5);

/// Wrong PINs allowed before the person is signed out.
const kAppLockMaxFailures = 5;

/// Whether this build offers an app PIN at all.
bool get appLockSupported => !kIsWeb;

const appLockPinStorageKey = 'app_lock_pin';
const appLockFailuresStorageKey = 'app_lock_failures';

/// PBKDF2 work factor for new PINs. The keychain/keystore is the real protection (a 4–6 digit
/// PIN has at most a million values); hashing just means a dumped storage value is not the PIN.
const kAppLockPbkdf2Iterations = 60000;

/// Why a proposed PIN is rejected, or `null` when it is acceptable.
String? appPinProblem(String pin) {
  if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) return 'Use 4 to 6 digits';
  if (pin.split('').toSet().length == 1) return 'Avoid repeating one digit';
  const ascending = '01234567890';
  const descending = '09876543210';
  if (ascending.contains(pin) || descending.contains(pin)) {
    return 'Avoid a simple sequence like 1234';
  }
  return null;
}

/// A stored PIN: who it belongs to and its salted PBKDF2-HMAC-SHA256 hash.
class AppPinRecord {
  const AppPinRecord({
    required this.userId,
    required this.salt,
    required this.hash,
    required this.iterations,
  });

  final String userId;
  final List<int> salt;
  final List<int> hash;
  final int iterations;

  /// Hashes [pin] off the UI thread.
  static Future<AppPinRecord> create({
    required String userId,
    required String pin,
    int iterations = kAppLockPbkdf2Iterations,
    Random? random,
  }) async {
    final rng = random ?? Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    return AppPinRecord(
      userId: userId,
      salt: salt,
      hash: await _hash(pin, salt, iterations),
      iterations: iterations,
    );
  }

  /// Checks [pin] off the UI thread, in constant time.
  Future<bool> matches(String pin) async =>
      _constantTimeEquals(await _hash(pin, salt, iterations), hash);

  static Future<List<int>> _hash(String pin, List<int> salt, int iterations) =>
      compute(_pbkdf2Job, (utf8.encode(pin), salt, iterations));

  String encode() => jsonEncode({
        'v': 1,
        'user_id': userId,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'iterations': iterations,
      });

  static AppPinRecord? decode(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return AppPinRecord(
        userId: map['user_id'] as String,
        salt: base64Decode(map['salt'] as String),
        hash: base64Decode(map['hash'] as String),
        iterations: map['iterations'] as int,
      );
    } catch (_) {
      return null;
    }
  }
}

List<int> _pbkdf2Job((List<int>, List<int>, int) args) =>
    pbkdf2Sha256(args.$1, args.$2, args.$3);

/// One-block PBKDF2-HMAC-SHA256 (32-byte output).
@visibleForTesting
List<int> pbkdf2Sha256(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = List<int>.of(block);
  for (var i = 1; i < iterations; i++) {
    block = hmac.convert(block).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= block[j];
    }
  }
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Persists the PIN record and the wrong-PIN counter in secure storage.
class AppLockStore {
  const AppLockStore([this._storage = const SecureSessionStorage()]);

  final SecureSessionStorage _storage;

  Future<AppPinRecord?> loadRecord() async =>
      AppPinRecord.decode(await _storage.read(appLockPinStorageKey));

  Future<void> saveRecord(AppPinRecord record) =>
      _storage.write(appLockPinStorageKey, record.encode());

  Future<int> loadFailures() async =>
      int.tryParse(await _storage.read(appLockFailuresStorageKey) ?? '') ?? 0;

  Future<void> saveFailures(int failures) => failures == 0
      ? _storage.delete(appLockFailuresStorageKey)
      : _storage.write(appLockFailuresStorageKey, '$failures');

  Future<void> clear() async {
    await _storage.delete(appLockPinStorageKey);
    await _storage.delete(appLockFailuresStorageKey);
  }
}

final appLockStoreProvider =
    Provider<AppLockStore>((ref) => const AppLockStore());

class AppLockState {
  const AppLockState({this.record, this.locked = false, this.failures = 0});

  static const none = AppLockState();

  /// The PIN set on this device, or `null` when there is none.
  final AppPinRecord? record;

  /// True while the UI is covered by the unlock screen.
  final bool locked;

  /// Consecutive wrong PINs (persisted).
  final int failures;

  bool get hasPin => record != null;
  int get attemptsLeft => max(0, kAppLockMaxFailures - failures);

  AppLockState copyWith({
    AppPinRecord? record,
    bool clearRecord = false,
    bool? locked,
    int? failures,
  }) =>
      AppLockState(
        record: clearRecord ? null : (record ?? this.record),
        locked: locked ?? this.locked,
        failures: failures ?? this.failures,
      );
}

/// Loads the lock state for a cold start (app/bootstrap.dart overrides
/// [appLockInitialStateProvider] with it). A PIN belonging to someone other than the restored
/// session's user is discarded.
Future<AppLockState> loadInitialAppLockState({
  required AppLockStore store,
  required Session? session,
}) async {
  if (!appLockSupported) return AppLockState.none;
  try {
    final record = await store.loadRecord();
    if (record == null) return AppLockState.none;
    if (session == null || session.user.id != record.userId) {
      await store.clear();
      return AppLockState.none;
    }
    return AppLockState(
      record: record,
      locked: true,
      failures: await store.loadFailures(),
    );
  } catch (_) {
    // Storage unreadable: no PIN rather than a lock nobody can open.
    return AppLockState.none;
  }
}

final appLockInitialStateProvider =
    Provider<AppLockState>((ref) => AppLockState.none);

/// Signs the person out after too many wrong PINs or "Forgot PIN". Overridable in tests.
final appLockSignOutProvider = Provider<Future<void> Function()>(
  (ref) => () => signOutAndClearScopedData(ref.container),
);

enum AppUnlockResult { unlocked, wrongPin, signedOut, signOutFailed }

class AppLockController extends Notifier<AppLockState> {
  @override
  AppLockState build() => ref.read(appLockInitialStateProvider);

  AppLockStore get _store => ref.read(appLockStoreProvider);

  /// Covers the app if a PIN is set. No-op otherwise.
  void lock() {
    if (state.hasPin && !state.locked) state = state.copyWith(locked: true);
  }

  Future<AppUnlockResult> unlock(String pin) async {
    final record = state.record;
    if (record == null) {
      state = state.copyWith(locked: false);
      return AppUnlockResult.unlocked;
    }
    if (state.failures < kAppLockMaxFailures && await record.matches(pin)) {
      state = state.copyWith(locked: false, failures: 0);
      await _store.saveFailures(0);
      return AppUnlockResult.unlocked;
    }
    final failures = state.failures + 1;
    state = state.copyWith(failures: failures);
    await _store.saveFailures(failures);
    if (failures < kAppLockMaxFailures) return AppUnlockResult.wrongPin;
    return signOut();
  }

  /// Ends the session (too many wrong PINs, or "Forgot PIN"). The lock stays up if sign-out
  /// fails, e.g. offline, so a failure never opens the app.
  Future<AppUnlockResult> signOut() async {
    try {
      await ref.read(appLockSignOutProvider)();
    } catch (_) {
      return AppUnlockResult.signOutFailed;
    }
    await _forget();
    return AppUnlockResult.signedOut;
  }

  /// Sets (or replaces) the PIN for [userId]. Runs PBKDF2, so callers show progress.
  Future<void> setPin({required String userId, required String pin}) async {
    final record = await AppPinRecord.create(userId: userId, pin: pin);
    await _store.saveRecord(record);
    await _store.saveFailures(0);
    state = AppLockState(record: record);
  }

  /// Checks [pin] against the stored PIN without changing the lock (used before change/remove).
  Future<bool> verify(String pin) async =>
      await state.record?.matches(pin) ?? false;

  Future<void> removePin() => _forget();

  Future<void> _forget() async {
    state = AppLockState.none;
    try {
      await _store.clear();
    } catch (_) {
      // Sign-out's secure-storage wipe removes it anyway.
    }
  }

  /// Auth events from [appLockAuthSyncProvider].
  void onAuthEvent(AuthChangeEvent event, Session? session) {
    switch (event) {
      case AuthChangeEvent.signedOut:
        unawaited(_forget());
      // A fresh credential sign-in (password, email link) or a reset link proves more than the
      // PIN does: open the app and reset the counter. Session restores and token refreshes
      // arrive as initialSession / tokenRefreshed and leave the lock alone.
      case AuthChangeEvent.signedIn || AuthChangeEvent.passwordRecovery:
        final record = state.record;
        if (record != null &&
            session != null &&
            session.user.id != record.userId) {
          unawaited(_forget());
          return;
        }
        if (state.locked || state.failures > 0) {
          state = state.copyWith(locked: false, failures: 0);
          unawaited(_store.saveFailures(0));
        }
      default:
        break;
    }
  }
}

final appLockProvider =
    NotifierProvider<AppLockController, AppLockState>(AppLockController.new);

/// Side-effect only, watched once at the app root: feeds auth events to [AppLockController].
final appLockAuthSyncProvider = Provider<void>((ref) {
  if (!appLockSupported) return;
  ref.listen<AsyncValue<AuthState>>(authStateChangesProvider, (_, next) {
    final value = next.valueOrNull;
    if (value == null) return;
    ref.read(appLockProvider.notifier).onAuthEvent(value.event, value.session);
  });
});

/// Tracks time in the background and locks on return after [kAppLockTimeout].
class AppLockLifecycle {
  AppLockLifecycle(this._lock, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final void Function() _lock;
  final DateTime Function() _clock;
  DateTime? _backgroundedAt;

  void onStateChange(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _backgroundedAt ??= _clock();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since != null && _clock().difference(since) >= kAppLockTimeout) {
          _lock();
        }
      default:
        break;
    }
  }
}

/// Side-effect only, watched once at the app root: locks after time in the background.
final appLockLifecycleProvider = Provider<void>((ref) {
  if (!appLockSupported) return;
  final tracker = AppLockLifecycle(
    () => ref.read(appLockProvider.notifier).lock(),
  );
  final listener = AppLifecycleListener(onStateChange: tracker.onStateChange);
  ref.onDispose(listener.dispose);
});
