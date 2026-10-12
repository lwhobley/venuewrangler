import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/notifications/application/push_registration_service.dart';
import 'package:venuewrangler_mobile/features/notifications/data/notifications_repository.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  _FakeNotificationsRepository({this.failRevocation = false});

  final bool failRevocation;
  final List<String> registered = [];
  final List<String> revoked = [];

  @override
  Future<String> registerPushToken({
    required String venueId,
    required String token,
    required String platform,
  }) async {
    registered.add(token);
    return 'id-$token';
  }

  @override
  Future<void> unregisterPushToken(String token) async {
    if (failRevocation) throw StateError('offline');
    revoked.add(token);
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

  test('a failed revocation of the previous token does not block registration',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'pending_push_token_revocation': 'previous-account-token',
    });
    final repository = _FakeNotificationsRepository(failRevocation: true);

    final registered = await service(repository).registerForVenue('venue-1');

    expect(registered, isTrue);
    expect(repository.registered, ['device-token']);
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
    expect(repository.registered, ['device-token']);
    expect(
      await const FlutterSecureStorage().read(
        key: 'pending_push_token_revocation',
      ),
      isNull,
    );
  });
}
