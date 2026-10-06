import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../venues/application/venues_providers.dart';
import '../application/crm_providers.dart';
import '../domain/crm_beo.dart';
import '../domain/crm_contract.dart';
import 'crm_lead_detail_screen.dart';

/// CRM: leads, BEOs (banquet event orders), contracts, and a pipeline forecast. Manager-tier
/// only end to end (RLS has no select policy for staff/supervisor on any crm_* table — see
/// crm_schema.sql) — a staff member landing here simply sees empty lists, matching the
/// RLS-is-the-only-boundary convention used throughout this app.
class CrmScreen extends ConsumerWidget {
  const CrmScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('CRM'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Leads'),
              Tab(text: 'BEOs'),
              Tab(text: 'Contracts'),
              Tab(text: 'Forecast'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _LeadsTab(venueId: venue.id),
            _BeosTab(venueId: venue.id),
            _ContractsTab(venueId: venue.id),
            _ForecastTab(venueId: venue.id),
          ],
        ),
      ),
    );
  }
}

class _LeadsTab extends ConsumerWidget {
  const _LeadsTab({required this.venueId});

  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leadsAsync = ref.watch(crmLeadsProvider(venueId));

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateLeadDialog(context, ref),
        child: const Icon(Icons.person_add_alt_1_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(crmLeadsProvider(venueId)),
        child: leadsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load leads.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(crmLeadsProvider(venueId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (leads) {
            if (leads.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: const Center(child: Text('No leads yet.')),
                  ),
                ),
              );
            }
            return ListView(
              children: [
                for (final lead in leads)
                  ListTile(
                    title: Text(lead.fullName),
                    subtitle: Text(
                      [
                        lead.status,
                        if (lead.company != null) lead.company!,
                      ].join(' · '),
                    ),
                    trailing: lead.estimatedValueCents != null
                        ? Text(
                            '\$${(lead.estimatedValueCents! / 100).toStringAsFixed(0)}',
                          )
                        : null,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CrmLeadDetailScreen(lead: lead),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showCreateLeadDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final phoneController = TextEditingController();
    final companyController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New lead'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            TextField(
              controller: emailController,
              decoration: const InputDecoration(labelText: 'Email (optional)'),
            ),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(labelText: 'Phone (optional)'),
            ),
            TextField(
              controller: companyController,
              decoration:
                  const InputDecoration(labelText: 'Company (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (confirmed != true ||
        nameController.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    try {
      await ref.read(crmRepositoryProvider).createLead(
            venueId: venueId,
            fullName: nameController.text.trim(),
            email: emailController.text.trim().isEmpty
                ? null
                : emailController.text.trim(),
            phone: phoneController.text.trim().isEmpty
                ? null
                : phoneController.text.trim(),
            company: companyController.text.trim().isEmpty
                ? null
                : companyController.text.trim(),
          );
      ref.invalidate(crmLeadsProvider(venueId));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not create lead. Please try again.'),
          ),
        );
      }
    }
  }
}

class _BeosTab extends ConsumerWidget {
  const _BeosTab({required this.venueId});

  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final beosAsync = ref.watch(crmBeosProvider(venueId));

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateBeoDialog(context, ref),
        child: const Icon(Icons.event_note_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(crmBeosProvider(venueId)),
        child: beosAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const Center(child: Text('Could not load BEOs.')),
          data: (beos) {
            if (beos.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: const Center(child: Text('No BEOs yet.')),
                  ),
                ),
              );
            }
            return ListView(
              children: [
                for (final beo in beos) _BeoTile(beo: beo, venueId: venueId),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showCreateBeoDialog(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    final guestCountController = TextEditingController();
    DateTime? eventDate;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New BEO'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Event name'),
              ),
              TextField(
                controller: guestCountController,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Guest count (optional)'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  eventDate == null
                      ? 'Event date (optional)'
                      : eventDate.toString().split(' ').first,
                ),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (picked != null) setState(() => eventDate = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true ||
        nameController.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    try {
      await ref.read(crmRepositoryProvider).createBeo(
            venueId: venueId,
            eventName: nameController.text.trim(),
            eventDate: eventDate,
            guestCount: int.tryParse(guestCountController.text.trim()),
          );
      ref.invalidate(crmBeosProvider(venueId));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not create BEO. Please try again.'),
          ),
        );
      }
    }
  }
}

class _BeoTile extends ConsumerWidget {
  const _BeoTile({required this.beo, required this.venueId});

  final CrmBeo beo;
  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      title: Text(beo.eventName),
      subtitle: Text(
        [
          beo.status,
          if (beo.eventDate != null)
            beo.eventDate!.toLocal().toString().split(' ').first,
          if (beo.guestCount != null) '${beo.guestCount} guests',
        ].join(' · '),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            children: [
              if (beo.status != 'confirmed' && beo.status != 'cancelled')
                OutlinedButton(
                  onPressed: () async {
                    try {
                      await ref
                          .read(crmRepositoryProvider)
                          .updateBeoStatus(beoId: beo.id, status: 'confirmed');
                      ref.invalidate(crmBeosProvider(venueId));
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(_friendlyError(e))),
                        );
                      }
                    }
                  },
                  child: const Text('Confirm'),
                ),
              if (beo.status != 'cancelled')
                OutlinedButton(
                  onPressed: () async {
                    try {
                      await ref
                          .read(crmRepositoryProvider)
                          .updateBeoStatus(beoId: beo.id, status: 'cancelled');
                      ref.invalidate(crmBeosProvider(venueId));
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not cancel BEO.'),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Cancel'),
                ),
              FilledButton(
                onPressed: () async {
                  try {
                    final result = await ref
                        .read(crmRepositoryProvider)
                        .convertBeoToContract(beoId: beo.id);
                    ref.invalidate(crmContractsProvider(venueId));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            result.alreadyExisted
                                ? 'A contract already exists for this BEO.'
                                : 'Contract created.',
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(_friendlyError(e))),
                      );
                    }
                  }
                },
                child: const Text('Convert to contract'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('reservation_hold_conflict')) {
      return 'This time slot is already held by another confirmed event.';
    }
    return 'Something went wrong. Please try again.';
  }
}

class _ContractsTab extends ConsumerWidget {
  const _ContractsTab({required this.venueId});

  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contractsAsync = ref.watch(crmContractsProvider(venueId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(crmContractsProvider(venueId)),
      child: contractsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Could not load contracts.')),
        data: (contracts) {
          if (contracts.isEmpty) {
            return LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SizedBox(
                  height: constraints.maxHeight,
                  child: const Center(
                    child: Text(
                      'No contracts yet — convert a confirmed BEO to create one.',
                    ),
                  ),
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final contract in contracts)
                _ContractTile(contract: contract, venueId: venueId),
            ],
          );
        },
      ),
    );
  }
}

class _ContractTile extends ConsumerWidget {
  const _ContractTile({required this.contract, required this.venueId});

  final CrmContract contract;
  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(contract.contractNumber),
      subtitle: Text(
        [
          contract.status,
          if (contract.eventName != null) contract.eventName!,
        ].join(' · '),
      ),
      trailing: contract.status != 'fully_signed' &&
              contract.status != 'cancelled'
          ? PopupMenuButton<String>(
              onSelected: (status) async {
                try {
                  await ref.read(crmRepositoryProvider).updateContractStatus(
                        contractId: contract.id,
                        status: status,
                      );
                  ref.invalidate(crmContractsProvider(venueId));
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not update contract status.'),
                      ),
                    );
                  }
                }
              },
              itemBuilder: (context) => [
                for (final status in CrmContract.statuses)
                  if (status != contract.status)
                    PopupMenuItem(value: status, child: Text(status)),
              ],
            )
          : null,
    );
  }
}

class _ForecastTab extends ConsumerWidget {
  const _ForecastTab({required this.venueId});

  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forecastAsync = ref.watch(crmForecastProvider(venueId));
    final staleAsync = ref.watch(crmStaleLeadsProvider(venueId));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(crmForecastProvider(venueId));
        ref.invalidate(crmStaleLeadsProvider(venueId));
      },
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'Pipeline forecast',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          forecastAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const Text('Could not load forecast.'),
            data: (rows) => Column(
              children: [
                for (final row in rows)
                  Card(
                    child: ListTile(
                      title: Text(row.status),
                      subtitle: Text(
                        '${row.leadCount} lead${row.leadCount == 1 ? '' : 's'}',
                      ),
                      trailing: Text(
                        '\$${(row.weightedValueCents / 100).toStringAsFixed(0)}',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Stale leads (no activity in 5+ days)',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          staleAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const Text('Could not load stale leads.'),
            data: (leads) => leads.isEmpty
                ? const Text('No stale leads — nice work.')
                : Column(
                    children: [
                      for (final lead in leads)
                        ListTile(
                          title: Text(lead.fullName),
                          subtitle: Text(
                            '${lead.status} · ${lead.daysSinceActivity} days since activity',
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
