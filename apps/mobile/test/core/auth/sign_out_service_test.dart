import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/core/auth/sign_out_service.dart';
import 'package:venuewrangler_mobile/core/network/supabase_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/core/storage/secure_session_storage.dart';
import 'package:venuewrangler_mobile/features/notifications/application/notifications_providers.dart';
import 'package:venuewrangler_mobile/features/notifications/application/push_registration_service.dart';
import 'package:venuewrangler_mobile/features/notifications/data/notifications_repository.dart';

class _Store implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    saved = mutations;
  }
}

class _Notifications implements NotificationsRepository {
  _Notifications({this.failRevocation = false});

  final bool failRevocation;
  final revoked = <(String, String?)>[];

  @override
  Future<void> unregisterPushToken(
    String token, {
    String? revocationSecret,
  }) async {
    if (failRevocation) throw StateError('offline');
    revoked.add((token, revocationSecret));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Auth implements AuthRepository {
  _Auth({this.failSignOut = false});

  Session? session;
  final bool failSignOut;
  int signOutCalls = 0;

  @override
  Session? get currentSession => session;

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (failSignOut) throw StateError('network');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Session _session(String userId) => Session(
      accessToken: 'access',
      tokenType: 'bearer',
      user: User(
        id: userId,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
      ),
    );

PendingMutation _queued(String id, String? userId) => PendingMutation(
      id: id,
      kind: 'test_kind',
      payload: const {},
      createdAt: DateTime(2026),
      userId: userId,
    );

void main() {
  late _Store store;
  late _Notifications notifications;
  late _Auth auth;
  late int pickerCleanups;
  late StreamController<AuthState> authEvents;
  String? currentUser;

  Future<ProviderContainer> makeContainer({
    bool failRevocation = false,
    bool failSignOut = false,
  }) async {
    notifications = _Notifications(failRevocation: failRevocation);
    auth = _Auth(failSignOut: failSignOut);
    final container = ProviderContainer(
      overrides: [
        offlineQueueStoreProvider.overrideWithValue(store),
        notificationsRepositoryProvider.overrideWithValue(notifications),
        pushRegistrationServiceProvider.overrideWith(
          (ref) => PushRegistrationService(
            repository: notifications,
            isIOS: () => false,
            isAndroid: () => false,
          ),
        ),
        authRepositoryProvider.overrideWithValue(auth),
        currentUserIdProvider.overrideWith((ref) => currentUser),
        authStateChangesProvider.overrideWith((ref) => authEvents.stream),
        pickerTemporaryFilesCleanerProvider
            .overrideWithValue(() async => pickerCleanups++),
      ],
    );
    addTearDown(container.dispose);
    await container.read(offlineQueueControllerProvider.notifier).ready;
    return container;
  }

  setUp(() {
    store = _Store()
      ..saved = [
        _queued('a-pending', 'user-a'),
        _queued('b-pending', 'user-b'),
      ];
    FlutterSecureStorage.setMockInitialValues({
      registeredPushTokenStorageKey: 'device-token',
      pushInstallationSecretStorageKey: 'install-secret',
      'supabase_persist_session': 'session-json',
      'floor_draft_user-a_plan': '{"tables": []}',
      'theme_mode': 'dark',
    });
    pickerCleanups = 0;
    currentUser = 'user-a';
    authEvents = StreamController<AuthState>.broadcast();
    addTearDown(authEvents.close);
  });

  Future<Map<String, String>> storedValues() =>
      const FlutterSecureStorage().readAll();

  group('signOutAndClearScopedData (UI sign-out)', () {
    test('revokes the push token, prunes the queue, wipes storage, signs out',
        () async {
      final container = await makeContainer();

      await signOutAndClearScopedData(container);

      expect(notifications.revoked, [('device-token', 'install-secret')]);
      expect(store.saved.map((m) => m.id), ['b-pending']);
      expect(pickerCleanups, 1);
      final values = await storedValues();
      expect(values.containsKey(registeredPushTokenStorageKey), isFalse);
      expect(values.containsKey('supabase_persist_session'), isFalse);
      expect(values.containsKey('floor_draft_user-a_plan'), isFalse);
      // Device-level settings and the install secret survive.
      expect(values['theme_mode'], 'dark');
      expect(values[pushInstallationSecretStorageKey], 'install-secret');
      expect(auth.signOutCalls, 1);
    });

    test('a failed revocation is queued for the next sign-in, not lost',
        () async {
      final container = await makeContainer(failRevocation: true);

      await signOutAndClearScopedData(container);

      final values = await storedValues();
      expect(values[pendingPushTokenRevocationStorageKey], 'device-token');
      expect(values.containsKey(registeredPushTokenStorageKey), isFalse);
      expect(auth.signOutCalls, 1);
    });

    test('a failing step never stops the others or the sign-out', () async {
      final container = await makeContainer();
      final failing = ProviderContainer(
        parent: container,
        overrides: [
          pickerTemporaryFilesCleanerProvider
              .overrideWithValue(() async => throw StateError('no channel')),
        ],
      );
      addTearDown(failing.dispose);

      await signOutAndClearScopedData(failing);

      expect(store.saved.map((m) => m.id), ['b-pending']);
      expect(
        (await storedValues()).containsKey('supabase_persist_session'),
        isFalse,
      );
      expect(auth.signOutCalls, 1);
    });
  });

  group('serverSignOutCleanupProvider (server-initiated sign-out)', () {
    Future<void> emit(AuthChangeEvent event, Session? session) async {
      authEvents.add(AuthState(event, session));
      await pumpEventQueue(times: 50);
    }

    test('runs every cleanup step when the session ends on its own', () async {
      final container = await makeContainer();
      container.read(serverSignOutCleanupProvider);
      await emit(AuthChangeEvent.signedIn, _session('user-a'));
      currentUser = null; // the session is gone by the time signedOut arrives

      await emit(AuthChangeEvent.signedOut, null);

      expect(notifications.revoked, [('device-token', 'install-secret')]);
      expect(store.saved.map((m) => m.id), ['b-pending']);
      expect(pickerCleanups, 1);
      final values = await storedValues();
      expect(values.containsKey('supabase_persist_session'), isFalse);
      expect(values.containsKey('floor_draft_user-a_plan'), isFalse);
      expect(values['theme_mode'], 'dark');
    });

    test('an unreachable server leaves the revocation queued', () async {
      final container = await makeContainer(failRevocation: true);
      container.read(serverSignOutCleanupProvider);
      await emit(AuthChangeEvent.signedIn, _session('user-a'));

      await emit(AuthChangeEvent.signedOut, null);

      expect(
        (await storedValues())[pendingPushTokenRevocationStorageKey],
        'device-token',
      );
    });

    test('a UI sign-out is not cleaned up a second time by the listener',
        () async {
      final container = await makeContainer();
      container.read(serverSignOutCleanupProvider);
      await emit(AuthChangeEvent.signedIn, _session('user-a'));

      await signOutAndClearScopedData(container);
      await emit(AuthChangeEvent.signedOut, null);

      expect(notifications.revoked, hasLength(1));
      expect(pickerCleanups, 1);
    });

    test('the next session is cleaned up again after signing back in',
        () async {
      final container = await makeContainer();
      container.read(serverSignOutCleanupProvider);
      await emit(AuthChangeEvent.signedIn, _session('user-a'));
      await emit(AuthChangeEvent.signedOut, null);
      expect(pickerCleanups, 1);

      await emit(AuthChangeEvent.signedIn, _session('user-b'));
      await emit(AuthChangeEvent.signedOut, null);

      expect(pickerCleanups, 2);
      // user-a's entries went with the first sign-out, user-b's with the second.
      expect(store.saved, isEmpty);
    });

    test('a failed UI sign-out re-arms the listener cleanup', () async {
      final container = await makeContainer(failSignOut: true);
      container.read(serverSignOutCleanupProvider);
      await emit(AuthChangeEvent.signedIn, _session('user-a'));

      await expectLater(
        signOutAndClearScopedData(container),
        throwsStateError,
      );
      await emit(AuthChangeEvent.signedOut, null);

      expect(pickerCleanups, 2);
    });

    test('a signed-out event with no known owner prunes no queue entries',
        () async {
      final container = await makeContainer();
      container.read(serverSignOutCleanupProvider);
      currentUser = null;

      await emit(AuthChangeEvent.signedOut, null);

      expect(pickerCleanups, 1);
      expect(
        container
            .read(offlineQueueControllerProvider)
            .pending
            .map((m) => m.id)
            .toSet(),
        {'a-pending', 'b-pending'},
      );
    });
  });

  test('the owner is seeded from an existing session at startup', () async {
    final container = await makeContainer();
    auth.session = _session('user-a');
    container.read(serverSignOutCleanupProvider);
    currentUser = null;

    await runSignOutCleanup(container);

    expect(store.saved.map((m) => m.id), ['b-pending']);
  });
}
