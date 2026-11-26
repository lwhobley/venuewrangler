import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/mfa_step_up.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/core/errors/server_denials.dart';
import 'package:venuewrangler_mobile/features/integrations/data/brighthr_repository.dart';
import 'package:venuewrangler_mobile/features/integrations/data/integrations_repository.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/time_clock_repository.dart';

import '../../features/mfa/fake_mfa_repository.dart';

void main() {
  group('mfa_required', () {
    test('is recognised from Postgres, Edge Functions and mapped errors', () {
      expect(
        isMfaRequired(
          const PostgrestException(message: 'mfa_required', code: '42501'),
        ),
        isTrue,
      );
      expect(
        isMfaRequired(
          FunctionException(status: 403, details: {'error': 'mfa_required'}),
        ),
        isTrue,
      );
      expect(isMfaRequired(const MfaRequiredError()), isTrue);

      expect(
        isMfaRequired(
          const PostgrestException(message: 'forbidden', code: '42501'),
        ),
        isFalse,
      );
      expect(
        isMfaRequired(
          FunctionException(status: 403, details: {'error': 'forbidden'}),
        ),
        isFalse,
      );
      expect(isMfaRequired(Exception('mfa_required')), isFalse);
    });

    test('BrightHR maps it to the step-up message', () {
      final error = mapBrightHrFunctionError(403, {'error': 'mfa_required'});
      expect(error, isA<MfaRequiredError>());
      expect(error.message, 'Verify with your authenticator to continue.');
    });

    test('payroll connect maps both MFA answers', () {
      expect(
        mapPayrollFunctionException(
          FunctionException(status: 403, details: {'error': 'mfa_required'}),
        ),
        isA<MfaRequiredError>(),
      );
      expect(
        mapPayrollFunctionException(
          FunctionException(
            status: 503,
            details: {'error': 'mfa_check_unavailable'},
          ),
        ).message,
        mfaCheckUnavailableMessage,
      );
    });

    test('an unavailable MFA check asks the person to try again', () {
      final error =
          mapBrightHrFunctionError(503, {'error': 'mfa_check_unavailable'});
      expect(error, isNot(isA<MfaRequiredError>()));
      expect(
        error.message,
        "Couldn't verify your sign-in security right now. Try again.",
      );
      expect(
        isMfaRequired(
          FunctionException(
            status: 503,
            details: {'error': 'mfa_check_unavailable'},
          ),
        ),
        isFalse,
      );
    });

    /// Taps a button that runs [action] through [runWithMfaStepUp]; whatever it throws lands
    /// in the returned list (it may still be waiting on a dialog when this returns).
    Future<List<Object>> runWith(
      WidgetTester tester,
      FakeMfaRepository mfa,
      Future<String> Function() action,
    ) async {
      final thrown = <Object>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async {
                  try {
                    await runWithMfaStepUp(context, ref, action);
                  } catch (error) {
                    thrown.add(error);
                  }
                },
                child: const Text('Go'),
              ),
            ),
          ),
          GoRoute(
            path: '/mfa',
            builder: (context, state) => const Text('MFA settings'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mfaRepositoryProvider.overrideWithValue(mfa)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      return thrown;
    }

    testWidgets('without an authenticator, offers enrolment and does not retry',
        (tester) async {
      var calls = 0;
      final thrown = await runWith(tester, FakeMfaRepository(), () async {
        calls++;
        throw FunctionException(
          status: 403,
          details: {'error': 'mfa_required'},
        );
      });

      expect(find.text('Two-factor authentication required'), findsOneWidget);
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();

      expect(find.text('MFA settings'), findsOneWidget);
      expect(calls, 1);
      expect(thrown.single, isA<MfaRequiredError>());
      expect(
        (thrown.single as MfaRequiredError).message,
        mfaEnrolmentRequiredMessage,
      );
    });

    testWidgets('other errors pass through untouched', (tester) async {
      final thrown = await runWith(
        tester,
        FakeMfaRepository(),
        () async => throw const PostgrestException(
          message: 'forbidden',
          code: '42501',
        ),
      );
      expect(find.text('Two-factor authentication required'), findsNothing);
      expect(thrown.single, isA<PostgrestException>());
    });
  });

  group('venue location not configured', () {
    const dbError = PostgrestException(
      message: 'Venue location is not configured. Ask a manager to set it in '
          'Settings before clocking in.',
      code: '42501',
    );

    test('the database trigger message is recognised', () {
      expect(isVenueGeofenceRequired(dbError), isTrue);
      expect(
        isVenueGeofenceRequired(
          const PostgrestException(
            message: 'outside venue geofence',
            code: '42501',
          ),
        ),
        isFalse,
      );
    });

    test('a direct punch shows the set-up message, not "outside geofence"', () {
      final error = mapTimeClockPostgrestException(dbError);
      expect(error, isA<PermissionDeniedError>());
      expect(
        error.message,
        "This venue's location isn't set up yet. Ask a manager to set it in "
        'venue settings.',
      );
      expect(
        mapTimeClockPostgrestException(
          const PostgrestException(
            message: 'outside venue geofence',
            code: '42501',
          ),
        ).message,
        contains('outside the venue geofence'),
      );
    });
  });
}
