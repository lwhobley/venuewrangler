import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/team/application/team_providers.dart';
import 'package:venuewrangler_mobile/features/team/data/team_repository.dart';
import 'package:venuewrangler_mobile/features/team/domain/team_error.dart';
import 'package:venuewrangler_mobile/features/team/domain/team_member.dart';
import 'package:venuewrangler_mobile/features/team/presentation/team_dialogs.dart';
import 'package:venuewrangler_mobile/features/team/presentation/team_member_tile.dart';
import 'package:venuewrangler_mobile/features/team/presentation/team_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeTeamRepository implements TeamRepository {
  _FakeTeamRepository(this.members);

  List<TeamMember> members;
  Object? removeError;
  final removed = <String>[];
  final roleChanges = <(String, String)>[];
  final transfers = <String>[];

  @override
  Future<List<TeamMember>> fetchMembers(String venueId) async => members;

  @override
  Future<void> removeMember(String membershipId) async {
    if (removeError != null) throw removeError!;
    removed.add(membershipId);
    members = [
      for (final m in members)
        if (m.membershipId != membershipId) m,
    ];
  }

  @override
  Future<void> changeRole(String membershipId, String newRole) async {
    roleChanges.add((membershipId, newRole));
  }

  @override
  Future<void> transferOwnership({
    required String organizationId,
    required String newOwnerUserId,
  }) async {
    transfers.add(newOwnerUserId);
  }
}

TeamMember _member(
  String id,
  String name,
  String role, {
  String? venueId = 'venue-1',
}) =>
    TeamMember(
      membershipId: 'm-$id',
      userId: id,
      role: role,
      organizationId: 'org-1',
      displayName: name,
      venueId: venueId,
    );

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  Future<_FakeTeamRepository> pumpTeam(
    WidgetTester tester, {
    required String role,
    List<TeamMember>? members,
  }) async {
    final repository = _FakeTeamRepository(
      members ??
          [
            _member('me', 'Me Myself', role, venueId: null),
            _member('u2', 'Sam Server', 'staff'),
            _member('u3', 'Pat Owner', 'organization_owner', venueId: null),
          ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          teamRepositoryProvider.overrideWithValue(repository),
          currentUserIdProvider.overrideWithValue('me'),
          myVenueRoleProvider.overrideWith((ref) async => role),
          activeVenueProvider.overrideWith((ref) => venue),
        ],
        child: const MaterialApp(home: TeamScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('lists org-level and venue members and marks the caller',
      (tester) async {
    await pumpTeam(tester, role: 'organization_owner');

    expect(
      find.text('Organization owners and admins'.toUpperCase()),
      findsOneWidget,
    );
    expect(find.text('Me Myself (you)'), findsOneWidget);
    expect(find.text('Sam Server'), findsOneWidget);
    expect(find.text('Pat Owner'), findsOneWidget);
    // Owner caller: a menu on both other rows, plus step-down on their own (a co-owner exists).
    expect(find.byType(PopupMenuButton<TeamMemberAction>), findsNWidgets(3));
  });

  testWidgets('supervisors get no team management', (tester) async {
    await pumpTeam(tester, role: 'supervisor');

    expect(
      find.text('Only managers and owners can manage the team.'),
      findsOneWidget,
    );
    expect(find.text('Sam Server'), findsNothing);
  });

  testWidgets('removing asks for confirmation, then removes and refreshes',
      (tester) async {
    final repository = await pumpTeam(tester, role: 'venue_manager');

    await tester.tap(find.byTooltip('Actions for Sam Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from team'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Sam Server?'), findsOneWidget);

    // Cancelling removes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.removed, isEmpty);

    await tester.tap(find.byTooltip('Actions for Sam Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from team'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(repository.removed, ['m-u2']);
    expect(find.text('Sam Server was removed.'), findsOneWidget);
    expect(find.text('Sam Server'), findsNothing);
  });

  testWidgets('a last_owner rejection is shown as a friendly message',
      (tester) async {
    final repository = await pumpTeam(
      tester,
      role: 'organization_owner',
      members: [
        _member('me', 'Me Myself', 'organization_owner', venueId: null),
        _member('u3', 'Pat Owner', 'organization_owner', venueId: null),
      ],
    );
    repository.removeError = const TeamException(
      'An organization needs at least one owner. Make someone else an owner '
      'first.',
    );

    await tester.tap(find.byTooltip('Actions for Pat Owner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from team'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.textContaining('at least one owner'), findsOneWidget);
    expect(find.text('Pat Owner'), findsOneWidget);
  });

  testWidgets('changing a role offers only roles the caller may assign',
      (tester) async {
    final repository = await pumpTeam(tester, role: 'venue_manager');

    await tester.tap(find.byTooltip('Actions for Sam Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change role'));
    await tester.pumpAndSettle();

    Finder inSheet(String text) => find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(text),
        );
    expect(find.text('Change role for Sam Server'), findsOneWidget);
    expect(inSheet('Manager'), findsOneWidget);
    expect(inSheet('Supervisor'), findsOneWidget);
    expect(inSheet('Owner'), findsNothing);

    await tester.tap(inSheet('Supervisor'));
    await tester.pumpAndSettle();

    expect(repository.roleChanges, [('m-u2', 'supervisor')]);
  });

  testWidgets('transferring ownership needs the typed confirmation word',
      (tester) async {
    final repository = await pumpTeam(tester, role: 'organization_owner');

    await tester.tap(find.byTooltip('Actions for Sam Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make co-owner'));
    await tester.pumpAndSettle();

    final transfer = find.widgetWithText(FilledButton, 'Make owner');
    expect(tester.widget<FilledButton>(transfer).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.pump();
    expect(tester.widget<FilledButton>(transfer).onPressed, isNull);

    await tester.enterText(find.byType(TextField), transferConfirmationWord);
    await tester.pump();
    await tester.tap(transfer);
    await tester.pumpAndSettle();

    expect(repository.transfers, ['u2']);
  });

  testWidgets('only owners are offered ownership transfer', (tester) async {
    await pumpTeam(tester, role: 'organization_admin');

    await tester.tap(find.byTooltip('Actions for Sam Server'));
    await tester.pumpAndSettle();

    expect(find.text('Make co-owner'), findsNothing);
    expect(find.text('Remove from team'), findsOneWidget);
  });

  testWidgets('an owner can step down to admin once another owner exists',
      (tester) async {
    final repository = await pumpTeam(tester, role: 'organization_owner');

    await tester.tap(find.byTooltip('Actions for Me Myself'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step down to admin'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Step down'));
    await tester.pumpAndSettle();

    expect(repository.roleChanges, [('m-me', 'organization_admin')]);
  });

  testWidgets('a sole owner has no step-down option', (tester) async {
    await pumpTeam(
      tester,
      role: 'organization_owner',
      members: [
        _member('me', 'Me Myself', 'organization_owner', venueId: null),
        _member('u2', 'Sam Server', 'staff'),
      ],
    );

    expect(find.byTooltip('Actions for Me Myself'), findsNothing);
  });
}
