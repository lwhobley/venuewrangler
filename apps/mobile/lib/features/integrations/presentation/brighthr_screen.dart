import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/application/workforce_providers.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/brighthr_providers.dart';
import '../domain/brighthr_models.dart';

/// BrightHR connection, employee linking, and the imported absences and Blip clock-ins.
/// Routed at `/integrations/brighthr`. See features/integrations/README.md.
class BrightHrScreen extends ConsumerWidget {
  const BrightHrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    final connectionAsync = ref.watch(brightHrConnectionProvider(venue.id));

    return connectionAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('BrightHR')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => Scaffold(
        appBar: AppBar(title: const Text('BrightHR')),
        body: _Retry(
          message: 'Could not load the BrightHR connection.',
          onRetry: () => ref.invalidate(brightHrConnectionProvider(venue.id)),
        ),
      ),
      data: (connection) => connection == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Connect BrightHR')),
              body: BrightHrConnectForm(venueId: venue.id),
            )
          : _ConnectedView(venueId: venue.id, connection: connection),
    );
  }
}

void _showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  final message = error is AppError
      ? error.message
      : 'Something went wrong. Try again when online.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class BrightHrConnectForm extends ConsumerStatefulWidget {
  const BrightHrConnectForm({super.key, required this.venueId});

  final String venueId;

  @override
  ConsumerState<BrightHrConnectForm> createState() =>
      _BrightHrConnectFormState();
}

class _BrightHrConnectFormState extends ConsumerState<BrightHrConnectForm> {
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final clientId = _clientId.text.trim();
    final clientSecret = _clientSecret.text.trim();
    if (clientId.isEmpty || clientSecret.isEmpty) {
      _showError(
        context,
        const UnknownError('Enter both the Client ID and the Client Secret.'),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(brightHrRepositoryProvider).connect(
            venueId: widget.venueId,
            clientId: clientId,
            clientSecret: clientSecret,
          );
      _clientSecret.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('BrightHR connected. Importing employees…'),
        ),
      );
      ref.invalidate(brightHrConnectionProvider(widget.venueId));
    } catch (error) {
      if (mounted) _showError(context, error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Import your BrightHR employees, approved absences and Blip clock-ins.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 16),
        Text('To get API credentials:', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          '1. Sign in to BrightHR as an administrator.\n'
          '2. Open account.brighthr.com/manage-api.\n'
          '3. Choose "Create new application", then "Create Secret".\n'
          '4. Copy the Client ID and Client Secret here. BrightHR only shows the secret once.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _clientId,
          enabled: !_submitting,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Client ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _clientSecret,
          enabled: !_submitting,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Client Secret',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show secret' : 'Hide secret',
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        Text(
          'The secret is encrypted and never shown again in the app.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }
}

class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.venueId, required this.connection});

  final String venueId;
  final BrightHrConnection connection;

  Future<void> _refresh(WidgetRef ref) {
    ref
      ..invalidate(brightHrEmployeesProvider(connection.id))
      ..invalidate(brightHrAbsencesProvider(connection.id))
      ..invalidate(brightHrClockingsProvider(connection.id));
    return ref.refresh(brightHrConnectionProvider(venueId).future);
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(brightHrRepositoryProvider).syncNow(venueId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sync started. Pull down to refresh in a minute.'),
        ),
      );
    } catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect BrightHR?'),
        content: const Text(
          'This removes the stored credentials, employee links and all imported BrightHR data '
          'from this venue. To fully revoke access, also delete the API application in '
          'BrightHR under API Management.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await container.read(brightHrRepositoryProvider).disconnect(venueId);
      container.invalidate(brightHrConnectionProvider(venueId));
    } catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('BrightHR'),
          actions: [
            IconButton(
              tooltip: 'Sync now',
              icon: const Icon(Icons.sync),
              onPressed: () => _sync(context, ref),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'disconnect') _disconnect(context, ref);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Employees'),
              Tab(text: 'Absences'),
              Tab(text: 'Clock-ins'),
            ],
          ),
        ),
        body: Column(
          children: [
            _StatusBanner(connection: connection),
            Expanded(
              child: TabBarView(
                children: [
                  RefreshIndicator(
                    onRefresh: () => _refresh(ref),
                    child: _EmployeesTab(
                      venueId: venueId,
                      connectionId: connection.id,
                    ),
                  ),
                  RefreshIndicator(
                    onRefresh: () => _refresh(ref),
                    child: _AbsencesTab(connectionId: connection.id),
                  ),
                  RefreshIndicator(
                    onRefresh: () => _refresh(ref),
                    child: _ClockingsTab(connectionId: connection.id),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.connection});

  final BrightHrConnection connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final lastSync = connection.lastSyncAt?.toLocal();
    final syncText = lastSync == null
        ? 'First sync in progress'
        : 'Last synced ${localizations.formatShortDate(lastSync)} '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(lastSync))}';
    final isProblem =
        connection.hasCredentialError || connection.lastSyncStatus == 'failed';
    final color = isProblem
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Material(
      color: color,
      child: ListTile(
        dense: true,
        leading: Icon(
          isProblem ? Icons.error_outline : Icons.check_circle_outline,
        ),
        title: Text('Client ID ${connection.maskedClientId} · $syncText'),
        subtitle:
            connection.lastError == null ? null : Text(connection.lastError!),
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Center(child: Text(message)),
        Center(
          child: TextButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    // A scrollable child keeps pull-to-refresh working on an empty tab.
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [Text(message, textAlign: TextAlign.center)],
    );
  }
}

Map<String, String> _namesById(List<BrightHrEmployee> employees) => {
      for (final e in employees) e.externalEmployeeId: e.displayName,
    };

class _EmployeesTab extends ConsumerWidget {
  const _EmployeesTab({required this.venueId, required this.connectionId});

  final String venueId;
  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employeesAsync = ref.watch(brightHrEmployeesProvider(connectionId));
    final rosterAsync = ref.watch(rosterForVenueProvider(venueId));

    return employeesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _Retry(
        message: 'Could not load BrightHR employees.',
        onRetry: () => ref.invalidate(brightHrEmployeesProvider(connectionId)),
      ),
      data: (employees) {
        if (employees.isEmpty) {
          return const _EmptyList(
            'No BrightHR employees imported yet. Pull down to refresh once the first sync finishes.',
          );
        }
        final roster = rosterAsync.valueOrNull ?? const <RosterMember>[];
        final rosterById = {for (final m in roster) m.userId: m};
        final linkedCount =
            employees.where((e) => e.linkedStaffId != null).length;
        return ListView.builder(
          itemCount: employees.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '$linkedCount of ${employees.length} linked. Absences and clock-ins '
                  'are imported only for linked employees.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            final employee = employees[index - 1];
            final linked = employee.linkedStaffId == null
                ? null
                : rosterById[employee.linkedStaffId];
            final details = [
              if (employee.jobTitle != null) employee.jobTitle!,
              if (employee.hasLeft) 'Left',
            ].join(' · ');
            return ListTile(
              title: Text(employee.displayName),
              subtitle: details.isEmpty ? null : Text(details),
              trailing: employee.linkedStaffId == null
                  ? const Text('Not linked')
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            linked?.displayName ?? 'Linked',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.link, size: 18),
                      ],
                    ),
              onTap: () => _pickMember(context, ref, employee, roster),
            );
          },
        );
      },
    );
  }

  Future<void> _pickMember(
    BuildContext context,
    WidgetRef ref,
    BrightHrEmployee employee,
    List<RosterMember> roster,
  ) async {
    final container = ProviderScope.containerOf(context, listen: false);
    // `''` stands for "unlink"; null means the sheet was dismissed.
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(
                  'Link ${employee.displayName} to',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (employee.linkedStaffId != null)
                ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('Unlink'),
                  onTap: () => Navigator.of(context).pop(''),
                ),
              if (roster.isEmpty)
                const ListTile(title: Text('No team members found.')),
              for (final member in roster)
                ListTile(
                  leading: Icon(
                    member.userId == employee.linkedStaffId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(member.displayName ?? 'Unnamed member'),
                  subtitle: Text(member.role.replaceAll('_', ' ')),
                  onTap: () => Navigator.of(context).pop(member.userId),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || choice == employee.linkedStaffId) return;
    try {
      await container.read(brightHrRepositoryProvider).link(
            venueId: venueId,
            externalEmployeeId: employee.externalEmployeeId,
            staffId: choice.isEmpty ? null : choice,
          );
      container.invalidate(brightHrEmployeesProvider(connectionId));
    } catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }
}

class _AbsencesTab extends ConsumerWidget {
  const _AbsencesTab({required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final absencesAsync = ref.watch(brightHrAbsencesProvider(connectionId));
    final names = _namesById(
      ref.watch(brightHrEmployeesProvider(connectionId)).valueOrNull ??
          const [],
    );
    final localizations = MaterialLocalizations.of(context);

    return absencesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _Retry(
        message: 'Could not load absences.',
        onRetry: () => ref.invalidate(brightHrAbsencesProvider(connectionId)),
      ),
      data: (absences) {
        if (absences.isEmpty) {
          return const _EmptyList(
            'No upcoming approved absences for linked employees.',
          );
        }
        return ListView.builder(
          itemCount: absences.length,
          itemBuilder: (context, index) {
            final absence = absences[index];
            final start = localizations.formatMediumDate(absence.startDate);
            final end = localizations.formatMediumDate(absence.endDate);
            final range =
                absence.startDate == absence.endDate ? start : '$start – $end';
            final halfDay =
                absence.startPart != 'FullDay' || absence.endPart != 'FullDay'
                    ? ' (part day)'
                    : '';
            return ListTile(
              leading: Icon(_absenceIcon(absence.type)),
              title: Text(
                names[absence.externalEmployeeId] ?? absence.externalEmployeeId,
              ),
              subtitle: Text('${absence.label} · $range$halfDay'),
              trailing: absence.covers(DateTime.now())
                  ? const Chip(label: Text('Today'))
                  : null,
            );
          },
        );
      },
    );
  }

  static IconData _absenceIcon(BrightHrAbsenceType type) => switch (type) {
        BrightHrAbsenceType.holiday => Icons.beach_access_outlined,
        BrightHrAbsenceType.sickness => Icons.healing_outlined,
        BrightHrAbsenceType.toil => Icons.more_time,
        BrightHrAbsenceType.other => Icons.event_busy_outlined,
      };
}

class _ClockingsTab extends ConsumerWidget {
  const _ClockingsTab({required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clockingsAsync = ref.watch(brightHrClockingsProvider(connectionId));
    final names = _namesById(
      ref.watch(brightHrEmployeesProvider(connectionId)).valueOrNull ??
          const [],
    );
    final localizations = MaterialLocalizations.of(context);
    String time(DateTime t) =>
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(t));

    return clockingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _Retry(
        message: 'Could not load clock-ins.',
        onRetry: () => ref.invalidate(brightHrClockingsProvider(connectionId)),
      ),
      data: (clockings) {
        if (clockings.isEmpty) {
          return const _EmptyList(
            'No Blip clock-ins in the last 14 days for linked employees.',
          );
        }
        return ListView.builder(
          itemCount: clockings.length,
          itemBuilder: (context, index) {
            final clocking = clockings[index];
            final out = clocking.clockOutAt;
            final duration = clocking.duration;
            final hours = duration == null
                ? 'Still clocked in'
                : '${duration.inHours}h ${(duration.inMinutes % 60).toString().padLeft(2, '0')}m';
            final breaks = clocking.breakCount == 0
                ? ''
                : ' · ${clocking.breakCount} break${clocking.breakCount == 1 ? '' : 's'}';
            return ListTile(
              title: Text(
                names[clocking.externalEmployeeId] ??
                    clocking.externalEmployeeId,
              ),
              subtitle: Text(
                '${localizations.formatMediumDate(clocking.clockInAt)} · '
                '${time(clocking.clockInAt)} – ${out == null ? '…' : time(out)}$breaks',
              ),
              trailing: Text(hours),
            );
          },
        );
      },
    );
  }
}
