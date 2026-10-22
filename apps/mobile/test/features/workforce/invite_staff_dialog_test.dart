import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/workforce/application/workforce_providers.dart';
import 'package:venuewrangler_mobile/features/workforce/data/workforce_repository.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';
import 'package:venuewrangler_mobile/features/workforce/presentation/invite_staff_dialog.dart';
import 'package:venuewrangler_mobile/features/workforce/presentation/pending_invites_section.dart';

Invite _inviteRow({
  String id = 'inv-1',
  String email = 'camila@example.com',
  WorkforceRole role = WorkforceRole.staff,
  DateTime? expiresAt,
  DateTime? lastSentAt,
}) =>
    Invite(
      id: id,
      venueId: 'venue-1',
      email: email,
      role: role,
      status: InviteStatus.pending,
      createdAt: DateTime(2026, 10, 1),
      fullName: 'Camila Reyes',
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(days: 10)),
      lastSentAt: lastSentAt,
    );

class _FakeWorkforceRepository implements WorkforceRepository {
  final created = <({String email, WorkforceRole role, String? fullName})>[];
  final emailed = <String>[];
  final resent = <String>[];
  Object? createError;
  Object? emailError;
  List<Invite> invites = [];

  @override
  Future<Invite> createInvite({
    required String venueId,
    required String email,
    required WorkforceRole role,
    String? fullName,
  }) async {
    if (createError != null) throw createError!;
    created.add((email: email, role: role, fullName: fullName));
    return _inviteRow(email: email, role: role);
  }

  @override
  Future<void> sendInviteEmail(String inviteId) async {
    if (emailError != null) throw emailError!;
    emailed.add(inviteId);
  }

  @override
  Future<Invite> resendInvite(String inviteId) async {
    resent.add(inviteId);
    return _inviteRow(id: '$inviteId-new');
  }

  @override
  Future<List<Invite>> fetchInvitesForVenue(String venueId) async => invites;

  @override
  Future<List<RosterMember>> fetchRosterForVenue(String venueId) async =>
      const [];

  @override
  Future<void> revokeInvite(String inviteId) async {}
}

class _FakeAiRepository implements AiRepository {
  Object? error;

  @override
  Future<StaffImportResult> parseStaffImport({
    required String venueId,
    required String pastedText,
  }) async {
    if (error != null) throw error!;
    return const StaffImportResult([
      StaffImportRow(fullName: 'Camila Reyes', email: 'camila@example.com'),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeWorkforceRepository> _pumpOpener(
  WidgetTester tester, {
  String? actorRole = 'venue_manager',
  _FakeAiRepository? ai,
}) async {
  final repository = _FakeWorkforceRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workforceRepositoryProvider.overrideWithValue(repository),
        if (ai != null) aiRepositoryProvider.overrideWithValue(ai),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showInviteStaffDialog(
                    context,
                    venueId: 'venue-1',
                    actorRole: actorRole,
                  ),
                  child: const Text('open invite'),
                ),
                TextButton(
                  onPressed: () => showStaffImportFlow(
                    context,
                    venueId: 'venue-1',
                    actorRole: actorRole,
                  ),
                  child: const Text('open import'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return repository;
}

Future<void> _fill(
  WidgetTester tester, {
  String name = '',
  String email = '',
}) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Full name'), name);
  await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
  await tester.tap(find.text('Send invite'));
  await tester.pumpAndSettle();
}

void main() {
  group('Invite staff dialog', () {
    testWidgets('a blank form stays open with the problems shown',
        (tester) async {
      final repository = await _pumpOpener(tester);
      await tester.tap(find.text('open invite'));
      await tester.pumpAndSettle();

      await _fill(tester);

      expect(find.text('Invite staff'), findsOneWidget);
      expect(find.text('Enter their name'), findsOneWidget);
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(repository.created, isEmpty);
    });

    testWidgets('a refused invite keeps the dialog and what was typed',
        (tester) async {
      final repository = await _pumpOpener(tester);
      repository.createError =
          const InviteActionException('That person is already on this team.');
      await tester.tap(find.text('open invite'));
      await tester.pumpAndSettle();

      await _fill(tester, name: 'Camila Reyes', email: 'camila@example.com');

      expect(find.text('Invite staff'), findsOneWidget);
      expect(find.text('That person is already on this team.'), findsOneWidget);
      expect(find.text('camila@example.com'), findsOneWidget);
    });

    testWidgets('saves the invite with the name, emails it and closes',
        (tester) async {
      final repository = await _pumpOpener(tester);
      await tester.tap(find.text('open invite'));
      await tester.pumpAndSettle();

      await _fill(tester, name: 'Camila Reyes', email: 'camila@example.com');

      expect(repository.created.single.fullName, 'Camila Reyes');
      expect(repository.created.single.role, WorkforceRole.staff);
      expect(repository.emailed, ['inv-1']);
      expect(find.text('Invite staff'), findsNothing);
      expect(
        find.text('Invitation emailed to camila@example.com.'),
        findsOneWidget,
      );
    });

    testWidgets('an email failure still closes and says the invite is saved',
        (tester) async {
      final repository = await _pumpOpener(tester);
      repository.emailError = const InviteActionException(
        'Too many invitation emails today. Try again tomorrow.',
      );
      await tester.tap(find.text('open invite'));
      await tester.pumpAndSettle();

      await _fill(tester, name: 'Camila Reyes', email: 'camila@example.com');

      expect(
        find.textContaining('Invite saved for camila@example.com'),
        findsOneWidget,
      );
    });

    testWidgets('managers are not offered the venue manager role',
        (tester) async {
      await _pumpOpener(tester);
      await tester.tap(find.text('open invite'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<WorkforceRole>));
      await tester.pumpAndSettle();

      expect(find.text('Venue manager'), findsNothing);
      expect(find.text('Supervisor'), findsWidgets);
    });

    testWidgets('owners can invite a venue manager', (tester) async {
      await _pumpOpener(tester, actorRole: 'organization_owner');
      await tester.tap(find.text('open invite'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<WorkforceRole>));
      await tester.pumpAndSettle();

      expect(find.text('Venue manager'), findsWidgets);
    });
  });

  group('Paste a staff list', () {
    testWidgets('a failed parse keeps the pasted text and shows why',
        (tester) async {
      final ai = _FakeAiRepository()
        ..error = const UnknownError('The assistant is busy. Try again.');
      await _pumpOpener(tester, ai: ai);
      await tester.tap(find.text('open import'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'Camila, camila@example.com',
      );
      await tester.tap(find.text('Parse'));
      await tester.pumpAndSettle();

      expect(find.text('Paste a staff list'), findsOneWidget);
      expect(find.text('The assistant is busy. Try again.'), findsOneWidget);
      expect(find.text('Camila, camila@example.com'), findsOneWidget);
    });

    testWidgets('a parsed row opens a pre-filled invite', (tester) async {
      await _pumpOpener(tester, ai: _FakeAiRepository());
      await tester.tap(find.text('open import'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Camila, camila@example.com',
      );
      await tester.tap(find.text('Parse'));
      await tester.pumpAndSettle();

      expect(find.text('Review parsed staff'), findsOneWidget);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();

      expect(find.text('Invite staff'), findsOneWidget);
      expect(find.text('Camila Reyes'), findsOneWidget);
      expect(find.text('camila@example.com'), findsOneWidget);
    });
  });

  group('Pending invites section', () {
    Future<_FakeWorkforceRepository> pumpSection(
      WidgetTester tester,
      List<Invite> invites, {
      String actorRole = 'venue_manager',
    }) async {
      final repository = _FakeWorkforceRepository()..invites = invites;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workforceRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PendingInvitesSection(
                venueId: 'venue-1',
                actorRole: actorRole,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('an expired invite says so and can be sent again',
        (tester) async {
      final repository = await pumpSection(tester, [
        _inviteRow(
          expiresAt: DateTime.now().subtract(const Duration(days: 3)),
        ),
      ]);

      expect(find.textContaining('Expired'), findsOneWidget);
      await tester.tap(find.text('Send a new invite'));
      await tester.pumpAndSettle();

      expect(repository.resent, ['inv-1']);
      expect(repository.emailed, ['inv-1-new']);
    });

    testWidgets('a manager cannot act on a manager invite', (tester) async {
      await pumpSection(tester, [
        _inviteRow(role: WorkforceRole.venueManager),
      ]);

      final resend = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Resend'),
      );
      expect(resend.onPressed, isNull);
    });
  });

  group('SupabaseWorkforceRepository', () {
    test('createInvite calls create_invite and maps refusals', () async {
      final requests = <http.Request>[];
      var refuse = false;
      final client = SupabaseClient(
        'https://workforce.test',
        'public-test-key',
        httpClient: MockClient((r) async {
          requests.add(r);
          if (refuse) {
            return http.Response(
              jsonEncode({'code': '42501', 'message': 'forbidden_role'}),
              403,
              request: r,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'id': 'inv-1',
              'venue_id': 'venue-1',
              'email': 'camila@example.com',
              'role': 'staff',
              'status': 'pending',
              'created_at': '2026-10-22T10:00:00Z',
              'expires_at': '2026-11-05T10:00:00Z',
              'full_name': 'Camila Reyes',
            }),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = SupabaseWorkforceRepository(client);

      final invite = await repository.createInvite(
        venueId: 'venue-1',
        email: 'camila@example.com',
        role: WorkforceRole.staff,
        fullName: 'Camila Reyes',
      );

      expect(requests.single.url.path, '/rest/v1/rpc/create_invite');
      expect(jsonDecode(requests.single.body), {
        'p_venue_id': 'venue-1',
        'p_email': 'camila@example.com',
        'p_role': 'staff',
        'p_full_name': 'Camila Reyes',
      });
      expect(invite.fullName, 'Camila Reyes');
      expect(invite.expiresAt, DateTime.utc(2026, 11, 5, 10));

      refuse = true;
      await expectLater(
        repository.createInvite(
          venueId: 'venue-1',
          email: 'mgr@example.com',
          role: WorkforceRole.venueManager,
        ),
        throwsA(
          isA<InviteActionException>().having(
            (e) => e.message,
            'message',
            contains('Only an owner or admin'),
          ),
        ),
      );
    });

    test('refusal messages', () {
      String message(String code, String text) => inviteActionExceptionFrom(
            PostgrestException(message: text, code: code),
          ).message;

      expect(message('P0001', 'already_member'), contains('already on this'));
      expect(message('22023', 'invalid_email'), contains('valid email'));
      expect(
        inviteActionExceptionFrom(
          const FunctionException(
            status: 429,
            details: {'error': 'rate_limited'},
          ),
        ).message,
        contains('Too many'),
      );
    });
  });
}
