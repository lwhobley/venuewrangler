import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/sign_out_service.dart';
import '../../../core/network/supabase_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/theme/theme_mode_provider.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../schedules/domain/schedule_timeline.dart';
import '../../schedules/domain/shift.dart';
import '../../settings/application/settings_providers.dart';
import '../../shift_mode/presentation/shift_widgets.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../../time_clock/domain/time_entry.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/domain/workforce_models.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _roleLabel(String? role) => switch (role) {
      'organization_owner' => 'Owner',
      'organization_admin' => 'Admin',
      null => 'Team member',
      _ => WorkforceRole.values
              .where((r) => r.toDb() == role)
              .map((r) => r.label)
              .firstOrNull ??
          'Team member',
    };

/// A person's own page: who they are here, their week, their upcoming shifts, and their
/// account settings.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final venue = ref.watch(activeVenueProvider);
    final userId = ref.watch(currentUserIdProvider);
    final email = ref.watch(supabaseClientProvider).auth.currentUser?.email;
    final profile = ref.watch(myProfileProvider).valueOrNull;
    final role = ref.watch(myVenueRoleProvider).valueOrNull;
    final shifts = venue == null
        ? const <Shift>[]
        : ref.watch(shiftsForVenueProvider(venue.id)).valueOrNull ??
            const <Shift>[];
    final entries = venue == null
        ? null
        : ref.watch(myTimeEntriesProvider(venue.id)).valueOrNull;

    final now = DateTime.now();
    final weekFrom = weekStart(now);
    final weekTo = weekFrom.add(const Duration(days: 7));
    final scheduled =
        userId == null ? 0.0 : scheduledHours(shifts, userId, weekFrom, weekTo);
    var workedMinutes = 0;
    for (final e in entries ?? const <TimeEntry>[]) {
      final start = e.clockInAt.toLocal();
      final end = (e.clockOutAt ?? now).toLocal();
      final a = start.isAfter(weekFrom) ? start : weekFrom;
      final b = end.isBefore(weekTo) ? end : weekTo;
      if (b.isAfter(a)) workedMinutes += b.difference(a).inMinutes;
    }
    final upcoming = [
      for (final s in shifts)
        if (s.staffId == userId &&
            s.status == ShiftStatus.scheduled &&
            s.endTime.isAfter(now))
          s,
    ]..sort((a, b) => a.startTime.compareTo(b.startTime));

    final name = profile?.displayName?.trim().isNotEmpty == true
        ? profile!.displayName!.trim()
        : (email ?? 'You');
    final initials = name
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();

    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  initials,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(color: theme.colorScheme.onPrimary),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.titleLarge),
                    Text(
                      [
                        _roleLabel(role),
                        if (venue != null) venue.name,
                      ].join(' · '),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (email != null)
                      Text(email, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const SectionTitle('This week'),
          Row(
            children: [
              Expanded(
                child: _Stat(label: 'Scheduled', value: formatHours(scheduled)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Stat(
                  label: 'Worked',
                  value:
                      entries == null ? '—' : formatHours(workedMinutes / 60),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const SectionTitle('Upcoming shifts'),
          if (upcoming.isEmpty)
            const CardShell(child: Text('No upcoming shifts scheduled.'))
          else
            CardShell(
              child: Column(
                children: [
                  for (final s in upcoming.take(5))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 96,
                            child: Text(
                              '${_weekdays[s.startTime.weekday - 1]} '
                              '${_months[s.startTime.month - 1]} ${s.startTime.day}',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '${clockLabel(s.startTime)}–${clockLabel(s.endTime)}'
                              '${s.roleLabel?.isNotEmpty == true ? ' · ${s.roleLabel}' : ''}'
                              '${s.section?.isNotEmpty == true ? ' · ${s.section}' : ''}',
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          const SectionTitle('Settings'),
          CardShell(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Appearance', style: theme.textTheme.labelMedium),
                const SizedBox(height: 8),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined),
                      label: Text('Dark'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined),
                      label: Text('Auto'),
                    ),
                  ],
                  selected: {ref.watch(themeModeProvider)},
                  onSelectionChanged: (s) =>
                      ref.read(themeModeProvider.notifier).set(s.first),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Display name'),
                  subtitle: Text(profile?.displayName ?? 'Not set'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editName(context, ref, profile?.displayName),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Change password'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _changePassword(context, ref),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout, color: context.ops.danger.fg),
                  title: Text(
                    'Sign out',
                    style: TextStyle(color: context.ops.danger.fg),
                  ),
                  onTap: () => signOutAndClearScopedData(ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editName(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final userId = ref.read(currentUserIdProvider);
    if (name == null || name.isEmpty || userId == null) return;
    try {
      await ref
          .read(settingsRepositoryProvider)
          .updateDisplayName(userId, name);
      ref.invalidate(myProfileProvider);
    } on PostgrestException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
        ),
      );
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (changed == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated.')),
      );
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _ChangePasswordDialog extends ConsumerStatefulWidget {
  const _ChangePasswordDialog();

  @override
  ConsumerState<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).updatePassword(_password.text);
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not update your password.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'New password'),
              validator: (v) => passwordPolicyProblem(v ?? ''),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password'),
              validator: (v) =>
                  v != _password.text ? "Passwords don't match" : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
