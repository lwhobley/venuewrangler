import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/invites/application/invites_providers.dart';
import 'package:venuewrangler_mobile/features/invites/data/invites_repository.dart';
import 'package:venuewrangler_mobile/features/invites/domain/pending_invite.dart';
import 'package:venuewrangler_mobile/features/invites/presentation/pending_invites_screen.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';

class _FakeInvitesRepository implements InvitesRepository {
  _FakeInvitesRepository(this.invites);

  List<PendingInvite> invites;
  Object? acceptError;
  final accepted = <String>[];

  @override
  Future<List<PendingInvite>> fetchPending() async => invites;

  @override
  Future<void> accept(String inviteId) async {
    if (acceptError != null) throw acceptError!;
    accepted.add(inviteId);
    invites = [
      for (final i in invites)
        if (i.inviteId != inviteId) i,
    ];
  }
}

PendingInvite _invite(String id, String venue) => PendingInvite(
      inviteId: id,
      organizationId: 'org-9',
      organizationName: 'Harbor Group',
      venueId: 'venue-$id',
      venueName: venue,
      role: 'staff',
    );

void main() {
  group('SupabaseInvitesRepository', () {
    test('fetchPending and accept call the invite RPCs', () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://invites.test',
        'public-test-key',
        httpClient: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('my_pending_invites')) {
            return http.Response(
              jsonEncode([
                {
                  'invite_id': 'i1',
                  'organization_id': 'o1',
                  'organization_name': 'Harbor Group',
                  'venue_id': 'v1',
                  'venue_name': 'The Pier',
                  'role': 'supervisor',
                  'invited_at': '2026-10-01T12:00:00Z',
                },
              ]),
              200,
              request: r,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 204, request: r);
        }),
      );
      addTearDown(client.dispose);
      final repo = SupabaseInvitesRepository(client);

      final invites = await repo.fetchPending();
      await repo.accept('i1');

      expect(invites.single.venueName, 'The Pier');
      expect(invites.single.role, 'supervisor');
      expect(requests[0].url.path, '/rest/v1/rpc/my_pending_invites');
      expect(requests[1].url.path, '/rest/v1/rpc/accept_invite');
      expect(jsonDecode(requests[1].body), {'p_invite_id': 'i1'});
    });

    test('a forbidden accept explains the email mismatch', () async {
      final client = SupabaseClient(
        'https://invites.test',
        'public-test-key',
        httpClient: MockClient(
          (r) async => http.Response(
            jsonEncode({'code': '42501', 'message': 'forbidden'}),
            403,
            request: r,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.dispose);

      await expectLater(
        SupabaseInvitesRepository(client).accept('i1'),
        throwsA(
          isA<InviteException>().having(
            (e) => e.message,
            'message',
            contains('different email'),
          ),
        ),
      );
    });
  });

  test('invite errors map to friendly messages', () {
    String message(String code, String text) => inviteExceptionFrom(
          PostgrestException(message: text, code: code),
        ).message;

    expect(
      message('42501', 'email_not_verified'),
      contains('Confirm your email'),
    );
    expect(message('P0001', 'invite_not_pending'), contains('already used'));
    expect(
      message('P0002', 'invite_not_found'),
      contains('no longer available'),
    );
  });

  group('invites prompt', () {
    ProviderContainer containerFor({
      required List<PendingInvite> invites,
      required List<Organization> organizations,
    }) {
      final container = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue('user-1'),
          invitesRepositoryProvider
              .overrideWithValue(_FakeInvitesRepository(invites)),
          myOrganizationsProvider.overrideWith((ref) async => organizations),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    final org = Organization(id: 'o1', name: 'Mine', createdAt: DateTime(2026));

    Future<bool> due(ProviderContainer container) async {
      await container.read(pendingInvitesProvider.future);
      await container.read(myOrganizationsProvider.future);
      return container.read(invitesPromptDueProvider);
    }

    test('is due only with invites and no organization', () async {
      expect(
        await due(
          containerFor(invites: [_invite('i1', 'Pier')], organizations: []),
        ),
        isTrue,
      );
      expect(
        await due(
          containerFor(
            invites: [_invite('i1', 'Pier')],
            organizations: [org],
          ),
        ),
        isFalse,
      );
      expect(
        await due(containerFor(invites: [], organizations: [])),
        isFalse,
      );
    });

    test('stops being due once dismissed', () async {
      final container =
          containerFor(invites: [_invite('i1', 'Pier')], organizations: []);
      expect(await due(container), isTrue);

      container.read(invitesPromptDismissedProvider.notifier).state = true;

      expect(container.read(invitesPromptDueProvider), isFalse);
    });
  });

  group('PendingInvitesScreen', () {
    Future<_FakeInvitesRepository> pump(
      WidgetTester tester,
      List<PendingInvite> invites,
    ) async {
      final repository = _FakeInvitesRepository(invites);
      final router = GoRouter(
        initialLocation: '/invites',
        routes: [
          GoRoute(
            path: '/invites',
            builder: (_, __) => const PendingInvitesScreen(),
          ),
          GoRoute(
            path: '/select-venue',
            builder: (_, __) => const Scaffold(body: Text('switcher')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('user-1'),
            invitesRepositoryProvider.overrideWithValue(repository),
            myOrganizationsProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('lists invites and nothing is joined until Accept',
        (tester) async {
      final repository = await pump(
        tester,
        [_invite('i1', 'The Pier'), _invite('i2', 'Dock')],
      );

      expect(find.text('The Pier'), findsOneWidget);
      expect(find.text('Dock'), findsOneWidget);
      expect(find.textContaining('Harbor Group'), findsNWidgets(2));
      expect(repository.accepted, isEmpty);
    });

    testWidgets('accepting the last invite joins and goes to the switcher',
        (tester) async {
      final repository = await pump(tester, [_invite('i1', 'The Pier')]);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(repository.accepted, ['i1']);
      expect(find.text('switcher'), findsOneWidget);
    });

    testWidgets('a failed accept shows the reason and keeps the invite',
        (tester) async {
      final repository = await pump(tester, [_invite('i1', 'The Pier')]);
      repository.acceptError = const InviteException(
        'This invite was sent to a different email address, or your email '
        'is not verified yet.',
      );

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(find.textContaining('different email address'), findsOneWidget);
      expect(find.text('The Pier'), findsOneWidget);
    });

    testWidgets('Decide later leaves without accepting', (tester) async {
      final repository = await pump(tester, [_invite('i1', 'The Pier')]);

      await tester.tap(find.text('Decide later'));
      await tester.pumpAndSettle();

      expect(repository.accepted, isEmpty);
      expect(find.text('switcher'), findsOneWidget);
    });
  });
}
