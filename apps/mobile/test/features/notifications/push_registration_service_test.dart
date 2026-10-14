import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/notifications/application/push_registration_service.dart';
import 'package:venuewrangler_mobile/features/notifications/data/notifications_repository.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  _FakeNotificationsRepository({
    this.failRevocation = false,
    this.registrationGate,
  });

  final bool failRevocation;
  final Completer<void>? registrationGate;
  final List<String> registered = [];
  final List<String> revoked = [];
  final List<String?> registrationSecrets = [];
  final List<String?> revocationSecrets = [];

  @override
  Future<String> registerPushToken({
    required String venueId,
    required String token,
    required String platform,
    String? revocationSecret,
  }) async {
    registered.add(token);
    registrationSecrets.add(revocationSecret);
    await registrationGate?.future;
    return 'id-$token';
  }

  @override
  Future<void> unregisterPushToken(
    String token, {
    String? revocationSecret,
  }) async {
    if (failRevocation) throw StateError('offline');
    revoked.add(token);
    revocationSecrets.add(revocationSecret);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/push_registration');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestPermissionAndRegister') return 'device-token';
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  PushRegistrationService service(NotificationsRepository repository) =>
      PushRegistrationService(
        repository: repository,
        iosChannel: channel,
        isIOS: () => true,
        isAndroid: () => false,
      );

  test('sign-out revokes a registration that finishes after disposal',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final gate = Completer<void>();
    final repository = _FakeNotificationsRepository(registrationGate: gate);
    final current = service(repository);
    final registration = current.registerForVenue('venue-1');
    for (var i = 0; i < 20 && repository.registered.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(repository.registered, ['device-token']);
    await current.dispose();
    gate.complete();
    expect(await registration, isFalse);
    expect(repository.revoked, ['device-token']);
    expect(repository.revocationSecrets, repository.registrationSecrets);
  });

  test('a failed revocation of the previous token does not block registration',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'pending_push_token_revocation': 'previous-account-token',
    });
    final repository = _FakeNotificationsRepository(failRevocation: true);

    final registered = await service(repository).registerForVenue('venue-1');

    expect(registered, isTrue);
    expect(repository.registered, ['device-token']);
    expect(
      repository.registrationSecrets.single,
      matches(RegExp(r'^[0-9a-f]{64}$')),
    );
    // The marker is kept so the revocation is retried on a later registration.
    final stored = await const FlutterSecureStorage().read(
      key: 'pending_push_token_revocation',
    );
    expect(stored, 'previous-account-token');
  });

  test('a pending revocation that succeeds is cleared before registering',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'pending_push_token_revocation': 'previous-account-token',
    });
    final repository = _FakeNotificationsRepository();

    expect(await service(repository).registerForVenue('venue-1'), isTrue);

    expect(repository.revoked, ['previous-account-token']);
    expect(
      repository.revocationSecrets.single,
      repository.registrationSecrets.single,
    );
    expect(repository.registered, ['device-token']);
    expect(
      await const FlutterSecureStorage().read(
        key: 'pending_push_token_revocation',
      ),
      isNull,
    );
  });
}
