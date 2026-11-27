import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/app_lock.dart';
import 'package:venuewrangler_mobile/features/auth/app_lock_screen.dart';

class _MemStore implements AppLockStore {
  AppPinRecord? record;
  int failures = 0;
  bool cleared = false;

  @override
  Future<AppPinRecord?> loadRecord() async => record;

  @override
  Future<void> saveRecord(AppPinRecord r) async => record = r;

  @override
  Future<int> loadFailures() async => failures;

  @override
  Future<void> saveFailures(int f) async => failures = f;

  @override
  Future<void> clear() async {
    cleared = true;
    record = null;
    failures = 0;
  }
}

Session _session(String userId) => Session(
      accessToken: 'token',
      tokenType: 'bearer',
      user: User(
        id: userId,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
      ),
    );

Future<AppPinRecord> _record(String pin, {String userId = 'user-1'}) =>
    AppPinRecord.create(userId: userId, pin: pin, iterations: 10);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('appPinProblem', () {
    test('accepts 4-6 digit PINs that are not trivial', () {
      expect(appPinProblem('2580'), isNull);
      expect(appPinProblem('739104'), isNull);
    });

    test('rejects wrong length, non-digits, repeats and sequences', () {
      for (final pin in [
        '123',
        '1234567',
        '12a4',
        '0000',
        '1234',
        '987654',
        '',
      ]) {
        expect(appPinProblem(pin), isNotNull, reason: pin);
      }
    });
  });

  group('PIN hashing', () {
    test('PBKDF2-HMAC-SHA256 matches the RFC 7914 test vector', () {
      expect(
        _hex(pbkdf2Sha256('password'.codeUnits, 'salt'.codeUnits, 1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        _hex(pbkdf2Sha256('password'.codeUnits, 'salt'.codeUnits, 2)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('a record round-trips through storage and checks the PIN', () async {
      final record = await _record('2580');
      final decoded = AppPinRecord.decode(record.encode())!;
      expect(decoded.userId, 'user-1');
      expect(await decoded.matches('2580'), isTrue);
      expect(await decoded.matches('2581'), isFalse);
      expect(record.encode(), isNot(contains('2580')));
      expect(AppPinRecord.decode('not json'), isNull);
    });
  });

  group('loadInitialAppLockState', () {
    test('locks a restored session that owns the PIN', () async {
      final store = _MemStore()
        ..record = await _record('2580')
        ..failures = 2;
      final state = await loadInitialAppLockState(
        store: store,
        session: _session('user-1'),
      );
      expect(state.locked, isTrue);
      expect(state.failures, 2);
    });

    test('drops a PIN that belongs to someone else or to no session', () async {
      for (final session in [_session('user-2'), null]) {
        final store = _MemStore()..record = await _record('2580');
        final state =
            await loadInitialAppLockState(store: store, session: session);
        expect(state.hasPin, isFalse);
        expect(state.locked, isFalse);
        expect(store.cleared, isTrue);
      }
    });
  });

  group('AppLockController', () {
    late _MemStore store;
    late int signOuts;
    late bool signOutFails;

    Future<ProviderContainer> containerWith({
      bool locked = true,
      int failures = 0,
    }) async {
      store = _MemStore()..failures = failures;
      store.record = await _record('2580');
      signOuts = 0;
      signOutFails = false;
      final container = ProviderContainer(
        overrides: [
          appLockStoreProvider.overrideWithValue(store),
          appLockInitialStateProvider.overrideWithValue(
            AppLockState(
              record: store.record,
              locked: locked,
              failures: failures,
            ),
          ),
          appLockSignOutProvider.overrideWithValue(() async {
            signOuts++;
            if (signOutFails) throw Exception('offline');
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the right PIN unlocks and resets the counter', () async {
      final c = await containerWith(failures: 3);
      final result = await c.read(appLockProvider.notifier).unlock('2580');
      expect(result, AppUnlockResult.unlocked);
      expect(c.read(appLockProvider).locked, isFalse);
      expect(store.failures, 0);
    });

    test('wrong PINs are counted and persisted', () async {
      final c = await containerWith();
      final result = await c.read(appLockProvider.notifier).unlock('1111');
      expect(result, AppUnlockResult.wrongPin);
      expect(c.read(appLockProvider).locked, isTrue);
      expect(c.read(appLockProvider).attemptsLeft, kAppLockMaxFailures - 1);
      expect(store.failures, 1);
    });

    test('the last allowed wrong PIN signs the person out', () async {
      final c = await containerWith(failures: kAppLockMaxFailures - 1);
      final result = await c.read(appLockProvider.notifier).unlock('1111');
      expect(result, AppUnlockResult.signedOut);
      expect(signOuts, 1);
      expect(c.read(appLockProvider).hasPin, isFalse);
      expect(store.cleared, isTrue);
    });

    test('once exhausted even the right PIN does not open the app', () async {
      final c = await containerWith(failures: kAppLockMaxFailures);
      signOutFails = true;
      final result = await c.read(appLockProvider.notifier).unlock('2580');
      expect(result, AppUnlockResult.signOutFailed);
      expect(c.read(appLockProvider).locked, isTrue);
    });

    test('a failed sign-out keeps the lock up', () async {
      final c = await containerWith();
      signOutFails = true;
      final result = await c.read(appLockProvider.notifier).signOut();
      expect(result, AppUnlockResult.signOutFailed);
      expect(c.read(appLockProvider).locked, isTrue);
      expect(c.read(appLockProvider).hasPin, isTrue);
    });

    test('a fresh password sign-in unlocks; a token refresh does not',
        () async {
      final c = await containerWith(failures: 2);
      final notifier = c.read(appLockProvider.notifier);
      notifier.onAuthEvent(AuthChangeEvent.tokenRefreshed, _session('user-1'));
      notifier.onAuthEvent(AuthChangeEvent.initialSession, _session('user-1'));
      expect(c.read(appLockProvider).locked, isTrue);
      notifier.onAuthEvent(AuthChangeEvent.signedIn, _session('user-1'));
      expect(c.read(appLockProvider).locked, isFalse);
      expect(c.read(appLockProvider).failures, 0);
    });

    test('another user signing in drops the PIN', () async {
      final c = await containerWith();
      c
          .read(appLockProvider.notifier)
          .onAuthEvent(AuthChangeEvent.signedIn, _session('user-2'));
      expect(c.read(appLockProvider).hasPin, isFalse);
      expect(c.read(appLockProvider).locked, isFalse);
    });

    test('sign-out forgets the PIN', () async {
      final c = await containerWith();
      c
          .read(appLockProvider.notifier)
          .onAuthEvent(AuthChangeEvent.signedOut, null);
      expect(c.read(appLockProvider).hasPin, isFalse);
    });

    test('lock() does nothing without a PIN', () async {
      final c = await containerWith(locked: false);
      await c.read(appLockProvider.notifier).removePin();
      c.read(appLockProvider.notifier).lock();
      expect(c.read(appLockProvider).locked, isFalse);
    });

    test(
      'setPin stores a new PIN and leaves the app unlocked',
      () async {
        final c = await containerWith(locked: false);
        await c
            .read(appLockProvider.notifier)
            .setPin(userId: 'user-1', pin: '4826');
        expect(await c.read(appLockProvider.notifier).verify('4826'), isTrue);
        expect(await c.read(appLockProvider.notifier).verify('2580'), isFalse);
        expect(c.read(appLockProvider).locked, isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('AppLockLifecycle', () {
    test('locks only after the timeout in the background', () {
      var now = DateTime(2026, 11, 26, 12);
      var locks = 0;
      final tracker = AppLockLifecycle(() => locks++, clock: () => now);

      tracker.onStateChange(AppLifecycleState.paused);
      now = now.add(kAppLockTimeout - const Duration(seconds: 1));
      tracker.onStateChange(AppLifecycleState.resumed);
      expect(locks, 0);

      tracker.onStateChange(AppLifecycleState.hidden);
      tracker.onStateChange(AppLifecycleState.paused);
      now = now.add(kAppLockTimeout);
      tracker.onStateChange(AppLifecycleState.resumed);
      expect(locks, 1);

      // Inactive alone (notification shade, system dialog) never starts the timer.
      tracker.onStateChange(AppLifecycleState.inactive);
      now = now.add(const Duration(hours: 1));
      tracker.onStateChange(AppLifecycleState.resumed);
      expect(locks, 1);
    });
  });

  testWidgets('AppLockGate covers the app and keeps it mounted',
      (tester) async {
    final record = await tester.runAsync(() => _record('2580'));
    final store = _MemStore()..record = record;
    final container = ProviderContainer(
      overrides: [
        appLockStoreProvider.overrideWithValue(store),
        appLockInitialStateProvider.overrideWithValue(
          AppLockState(record: record, locked: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => AppLockGate(child: child!),
          home: const Scaffold(body: Text('secret schedule')),
        ),
      ),
    );

    expect(find.text('Enter your PIN'), findsOneWidget);
    expect(find.text('secret schedule'), findsNothing);
    expect(find.text('secret schedule', skipOffstage: false), findsOneWidget);

    await tester.enterText(find.byKey(const Key('app-lock-pin')), '2580');
    await tester.runAsync(
      () => container.read(appLockProvider.notifier).unlock('2580'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter your PIN'), findsNothing);
    expect(find.text('secret schedule'), findsOneWidget);
  });
}
