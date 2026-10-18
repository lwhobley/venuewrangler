import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';

/// In-memory [MfaRepository] for widget and router tests.
class FakeMfaRepository implements MfaRepository {
  FakeMfaRepository({List<MfaFactor>? factors}) : factors = factors ?? [];

  List<MfaFactor> factors;
  bool required = false;
  Object? challengeError;
  Object? verifyError;
  final challenges = <(String, String)>[];
  final verifications = <(String, String)>[];
  final unenrolled = <String>[];

  @override
  bool get challengeRequired => required;

  @override
  Future<List<MfaFactor>> listFactors() async => factors;

  @override
  Future<MfaEnrollment> enrollTotp({String? issuer}) async =>
      const MfaEnrollment(
        factorId: 'new-factor',
        secret: 'JBSWY3DPEHPK3PXP',
        uri: 'otpauth://totp/Venue%20Wrangler:me?secret=JBSWY3DPEHPK3PXP',
      );

  @override
  Future<void> verifyEnrollment({
    required String factorId,
    required String code,
  }) async {
    if (verifyError != null) throw verifyError!;
    verifications.add((factorId, code));
    factors = [MfaFactor(id: factorId, verified: true)];
  }

  @override
  Future<void> challenge({
    required String factorId,
    required String code,
  }) async {
    if (challengeError != null) throw challengeError!;
    challenges.add((factorId, code));
  }

  @override
  Future<void> unenroll(String factorId) async {
    unenrolled.add(factorId);
    factors = [
      for (final f in factors)
        if (f.id != factorId) f,
    ];
  }
}
