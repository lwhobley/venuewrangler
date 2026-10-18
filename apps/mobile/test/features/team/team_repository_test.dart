import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/features/team/data/team_repository.dart';
import 'package:venuewrangler_mobile/features/team/domain/team_error.dart';
import 'package:venuewrangler_mobile/features/team/domain/team_member.dart';

SupabaseClient _client(
  List<http.Request> requests,
  http.Response Function(http.Request) respond,
) {
  final client = SupabaseClient(
    'https://team.test',
    'public-test-key',
    httpClient: MockClient((request) async {
      requests.add(request);
      return respond(request);
    }),
  );
  addTearDown(client.dispose);
  return client;
}

http.Response _json(Object? body, http.Request request, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      request: request,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('SupabaseTeamRepository', () {
    test('fetchMembers calls team_members and parses org and venue rows',
        () async {
      final requests = <http.Request>[];
      final repo = SupabaseTeamRepository(
        _client(
          requests,
          (r) => _json(
            [
              {
                'membership_id': 'm1',
                'user_id': 'u1',
                'role': 'organization_owner',
                'display_name': 'Olive Owner',
                'venue_id': null,
                'organization_id': 'o1',
              },
              {
                'membership_id': 'm2',
                'user_id': 'u2',
                'role': 'staff',
                'display_name': null,
                'venue_id': 'v1',
                'organization_id': 'o1',
              },
            ],
            r,
          ),
        ),
      );

      final members = await repo.fetchMembers('v1');

      expect(requests.single.url.path, '/rest/v1/rpc/team_members');
      expect(jsonDecode(requests.single.body), {'p_venue_id': 'v1'});
      expect(members, hasLength(2));
      expect(members[0].isOrgLevel, isTrue);
      expect(members[1].isOrgLevel, isFalse);
      expect(members[1].name, 'Unnamed member');
    });

    test('removeMember, changeRole and transferOwnership send the RPC params',
        () async {
      final requests = <http.Request>[];
      final repo = SupabaseTeamRepository(
        _client(requests, (r) => http.Response('', 204, request: r)),
      );

      await repo.removeMember('m2');
      await repo.changeRole('m2', 'supervisor');
      await repo.transferOwnership(
        organizationId: 'o1',
        newOwnerUserId: 'u2',
      );

      expect(requests.map((r) => r.url.path), [
        '/rest/v1/rpc/remove_member',
        '/rest/v1/rpc/change_member_role',
        '/rest/v1/rpc/transfer_ownership',
      ]);
      expect(jsonDecode(requests[0].body), {'p_membership_id': 'm2'});
      expect(jsonDecode(requests[1].body), {
        'p_membership_id': 'm2',
        'p_new_role': 'supervisor',
      });
      expect(jsonDecode(requests[2].body), {
        'p_organization_id': 'o1',
        'p_new_owner_user_id': 'u2',
      });
    });

    test('server errors surface as friendly TeamExceptions', () async {
      Future<String> messageFor(String code, String message) async {
        final repo = SupabaseTeamRepository(
          _client(
            [],
            (r) => _json({'code': code, 'message': message}, r, status: 400),
          ),
        );
        try {
          await repo.removeMember('m1');
        } on TeamException catch (error) {
          return error.message;
        }
        fail('expected a TeamException');
      }

      expect(
        await messageFor('P0001', 'last_owner'),
        contains('at least one owner'),
      );
      expect(
        await messageFor('P0001', 'cannot_modify_self'),
        contains("can't change your own"),
      );
      expect(
        await messageFor('P0001', 'role_not_allowed'),
        contains("isn't allowed"),
      );
      expect(
        await messageFor('42501', 'mfa_required'),
        contains('two-factor'),
      );
      expect(
        await messageFor('P0001', 'target_not_a_member'),
        contains('already a member'),
      );
      expect(
        await messageFor('42501', 'forbidden'),
        contains("don't have permission"),
      );
    });
  });

  group('TeamMember permissions', () {
    TeamMember member(
      String role, {
      String? venueId = 'v1',
      String id = 'u2',
    }) =>
        TeamMember(
          membershipId: 'm-$id',
          userId: id,
          role: role,
          organizationId: 'o1',
          venueId: venueId,
        );

    test('nobody manages themselves; supervisors and staff manage no one', () {
      expect(
        member('staff', id: 'me')
            .canBeManagedBy(callerRole: 'organization_owner', callerId: 'me'),
        isFalse,
      );
      expect(
        member('staff')
            .canBeManagedBy(callerRole: 'supervisor', callerId: 'me'),
        isFalse,
      );
      expect(
        member('staff').canBeManagedBy(callerRole: null, callerId: 'me'),
        isFalse,
      );
    });

    test('venue managers manage venue rows below them, not org-level rows', () {
      expect(
        member('staff')
            .canBeManagedBy(callerRole: 'venue_manager', callerId: 'me'),
        isTrue,
      );
      expect(
        member('venue_manager')
            .canBeManagedBy(callerRole: 'venue_manager', callerId: 'me'),
        isFalse,
      );
      expect(
        member('organization_admin', venueId: null)
            .canBeManagedBy(callerRole: 'venue_manager', callerId: 'me'),
        isFalse,
      );
    });

    test('owners manage everyone else; admins cannot touch owners', () {
      expect(
        member('organization_owner', venueId: null)
            .canBeManagedBy(callerRole: 'organization_owner', callerId: 'me'),
        isTrue,
      );
      expect(
        member('organization_owner', venueId: null)
            .canBeManagedBy(callerRole: 'organization_admin', callerId: 'me'),
        isFalse,
      );
      expect(
        member('venue_manager')
            .canBeManagedBy(callerRole: 'organization_admin', callerId: 'me'),
        isTrue,
      );
    });

    test('assignable roles stay on the row\'s level and never above the caller',
        () {
      expect(
        member('staff').assignableRolesFor('venue_manager'),
        ['venue_manager', 'supervisor'],
      );
      expect(
        member('staff').assignableRolesFor('organization_owner'),
        ['venue_manager', 'supervisor'],
      );
      expect(
        member('organization_admin', venueId: null)
            .assignableRolesFor('organization_owner'),
        ['organization_owner'],
      );
      expect(
        member('organization_owner', venueId: null)
            .assignableRolesFor('organization_admin'),
        ['organization_admin'],
      );
    });
  });
}
