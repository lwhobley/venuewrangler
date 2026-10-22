import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/workforce_providers.dart';
import '../domain/employee_hr_profile.dart';
import 'employee_profile_widgets.dart';
import 'invite_staff_dialog.dart';
import 'pending_invites_section.dart';
import '../../../core/privacy/screen_security.dart';

/// Team identity, HR profiles, and invitations for the active venue.
class WorkforceRosterScreen extends ConsumerWidget {
  const WorkforceRosterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final canManage =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    final rosterAsync = ref.watch(
      canManage
          ? rosterForVenueProvider(venue.id)
          : scheduleRosterForVenueProvider(venue.id),
    );
    final actorRole = ref.watch(myVenueRoleProvider).valueOrNull;
    final actorId = ref.watch(currentUserIdProvider);

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Team Management'),
          actions: [
            if (canManage)
              IconButton(
                tooltip: 'Import staff',
                icon: const Icon(Icons.upload_file_outlined),
                onPressed: () => showStaffImportFlow(
                  context,
                  venueId: venue.id,
                  actorRole: actorRole,
                ),
              ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(
              canManage
                  ? rosterForVenueProvider(venue.id)
                  : scheduleRosterForVenueProvider(venue.id),
            );
            if (canManage) {
              ref.invalidate(invitesForVenueProvider(venue.id));
            }
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const _SectionHeader('Roster'),
              rosterAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, __) =>
                    const ListTile(title: Text('Could not load roster.')),
                data: (roster) => roster.isEmpty
                    ? const ListTile(title: Text('No roster members yet.'))
                    : Column(
                        children: [
                          for (final member in roster)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Card(
                                child: ListTile(
                                  leading: StaffAvatar(
                                    profileKey: (
                                      venueId: venue.id,
                                      userId: member.userId
                                    ),
                                    name: member.displayName ?? 'Team member',
                                  ),
                                  title: Text(
                                    member.displayName ?? '(no name set)',
                                  ),
                                  subtitle:
                                      Text(member.role.replaceAll('_', ' ')),
                                  trailing: canManageEmployeeDetails(
                                            actorRole,
                                            member.role,
                                          ) ||
                                          actorId == member.userId
                                      ? const Icon(Icons.chevron_right)
                                      : null,
                                  onTap: canManageEmployeeDetails(
                                            actorRole,
                                            member.role,
                                          ) ||
                                          actorId == member.userId
                                      ? () => showModalBottomSheet<void>(
                                            context: context,
                                            isScrollControlled: true,
                                            useSafeArea: true,
                                            builder: (context) => SizedBox(
                                              height: MediaQuery.sizeOf(context)
                                                      .height *
                                                  .85,
                                              child: ListView(
                                                padding:
                                                    const EdgeInsets.all(16),
                                                children: [
                                                  Text(
                                                    member.displayName ??
                                                        'Team member',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleLarge,
                                                  ),
                                                  const SizedBox(height: 16),
                                                  Center(
                                                    child: StaffAvatar(
                                                      profileKey: (
                                                        venueId: venue.id,
                                                        userId: member.userId
                                                      ),
                                                      name:
                                                          member.displayName ??
                                                              'Team member',
                                                      radius: 40,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                  ProfilePhotoButton(
                                                    profileKey: (
                                                      venueId: venue.id,
                                                      userId: member.userId
                                                    ),
                                                    organizationId:
                                                        venue.organizationId,
                                                  ),
                                                  const SizedBox(height: 16),
                                                  EmployeeHrCard(
                                                    profileKey: (
                                                      venueId: venue.id,
                                                      userId: member.userId
                                                    ),
                                                    name: member.displayName ??
                                                        'Team member',
                                                    manageEmployment:
                                                        canManageEmployeeDetails(
                                                      actorRole,
                                                      member.role,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          )
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              if (canManage) ...[
                const Divider(),
                const _SectionHeader('Pending invites'),
                PendingInvitesSection(
                  venueId: venue.id,
                  actorRole: actorRole,
                ),
              ],
            ],
          ),
        ),
        bottomNavigationBar: canManage
            ? SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: () => showInviteStaffDialog(
                      context,
                      venueId: venue.id,
                      actorRole: actorRole,
                    ),
                    icon: const Icon(Icons.person_add_alt_outlined),
                    label: const Text('Add New Staff'),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}
