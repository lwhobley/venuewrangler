import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../application/crm_providers.dart';
import '../domain/beo_time.dart';
import '../domain/crm_beo.dart';
import '../domain/crm_contract.dart';
import 'beo_cancellation.dart';
import 'crm_form_dialogs.dart';
import 'enquiry_import_dialog.dart';
import 'crm_lead_detail_screen.dart';
import 'crm_beo_detail_screen.dart';

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
          actions: [
            IconButton(
              tooltip: 'New lead/BEO from enquiry',
              icon: const Icon(Icons.auto_awesome),
              onPressed: () => _showEnquiryDialog(context, ref, venue.id),
            ),
          ],
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

Future<void> _showEnquiryDialog(
  BuildContext context,
  WidgetRef ref,
  String venueId,
) async {
  final clock = ref.read(venueClockProvider);
  if (!ensureSupported(context, clock)) return;
  final created = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => EnquiryImportDialog(venueId: venueId, clock: clock),
  );
  if (created == true) {
    ref.invalidate(crmLeadsProvider(venueId));
    ref.invalidate(crmBeosProvider(venueId));
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
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => NewLeadDialog(venueId: venueId),
    );
    if (created == true) ref.invalidate(crmLeadsProvider(venueId));
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
    // The start time is entered and shown on the venue's clock, not the device's (D6).
    final clock = ref.read(venueClockProvider);
    if (!ensureSupported(context, clock)) return;
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => NewBeoDialog(venueId: venueId, clock: clock),
    );
    if (created == true) ref.invalidate(crmBeosProvider(venueId));
  }
}

class _BeoTile extends ConsumerStatefulWidget {
  const _BeoTile({required this.beo, required this.venueId});

  final CrmBeo beo;
  final String venueId;

  @override
  ConsumerState<_BeoTile> createState() => _BeoTileState();
}

class _BeoTileState extends ConsumerState<_BeoTile> {
  bool converting = false;
  bool saving = false;

  Future<void> _confirm() async {
    final beo = widget.beo;
    final clock = ref.read(venueClockProvider);
    // The database rejects confirming a BEO with no start time (22023), so explain that here
    // instead of showing a generic failure.
    if (beo.eventDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Set an event date before confirming this BEO.'),
        ),
      );
      return;
    }
    await _run(
      () => ref
          .read(crmRepositoryProvider)
          .updateBeoStatus(beoId: beo.id, status: 'confirmed'),
      clock,
    );
  }

  /// Asks first (naming the event, guests and charges), then cancels and offers Undo.
  Future<void> _cancel() async {
    final beo = widget.beo;
    final clock = ref.read(venueClockProvider);
    int? chargesCents;
    try {
      final charges = await ref.read(crmBeoChargesProvider(beo.id).future);
      chargesCents = charges.fold<int>(0, (t, c) => t + c.signedAmountCents);
    } catch (_) {
      chargesCents = null;
    }
    if (!mounted) return;
    final confirmed = await confirmCancelBeo(
      context,
      beo: beo,
      clock: clock,
      chargesCents: chargesCents,
    );
    if (!confirmed || !mounted) return;

    // Captured now: the tile is rebuilt (or gone) by the time Undo is tapped.
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final repo = ref.read(crmRepositoryProvider);
    final venueId = widget.venueId;
    final ok = await _run(
      () => repo.updateBeoStatus(beoId: beo.id, status: 'cancelled'),
      clock,
    );
    if (!ok) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('${beo.eventName} was cancelled.'),
        // [beo] is the pre-cancel snapshot; Undo is offered while its date has not passed.
        action: beo.eventDate == null || beo.eventDate!.isAfter(DateTime.now())
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  try {
                    await repo.restoreBeo(beoId: beo.id);
                    messenger.showSnackBar(
                      SnackBar(content: Text('${beo.eventName} was restored.')),
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(beoWriteErrorMessage(e, clock))),
                    );
                  } finally {
                    container.invalidate(crmBeosProvider(venueId));
                  }
                },
              )
            : null,
      ),
    );
  }

  Future<void> _restore() async {
    final beo = widget.beo;
    final ok = await _run(
      () => ref.read(crmRepositoryProvider).restoreBeo(beoId: beo.id),
      ref.read(venueClockProvider),
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${beo.eventName} was restored.')),
      );
    }
  }

  /// Runs a BEO status write, refreshes the list, and reports a failure. Returns whether it
  /// succeeded.
  Future<bool> _run(Future<void> Function() write, VenueClock clock) async {
    if (saving) return false;
    setState(() => saving = true);
    try {
      await write();
      ref.invalidate(crmBeosProvider(widget.venueId));
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(beoWriteErrorMessage(e, clock))),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final beo = widget.beo;
    final venueId = widget.venueId;
    final clock = ref.watch(venueClockProvider);
    return ExpansionTile(
      title: Text(beo.eventName),
      subtitle: Text(
        [
          beo.status,
          if (beo.eventDate != null) beoWhenLabel(beo.eventDate!, clock),
          if (beo.guestCount != null) '${beo.guestCount} guests',
        ].join(' · '),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CrmBeoDetailScreen(beo: beo),
                  ),
                ),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('View BEO'),
              ),
              if (beo.status != 'confirmed' && beo.status != 'cancelled')
                OutlinedButton(
                  onPressed: saving ? null : _confirm,
                  child: const Text('Confirm'),
                ),
              if (beo.status != 'cancelled')
                OutlinedButton(
                  onPressed: saving ? null : _cancel,
                  child: const Text('Cancel'),
                ),
              if (beo.canRestoreAt(DateTime.now()))
                OutlinedButton.icon(
                  onPressed: saving ? null : _restore,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore'),
                ),
              // Only a confirmed BEO can become a contract; draft/sent/cancelled ones cannot.
              if (beo.status == 'confirmed')
                FilledButton(
                  onPressed: converting
                      ? null
                      : () async {
                          setState(() => converting = true);
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
                                SnackBar(
                                  content: Text(beoWriteErrorMessage(e, clock)),
                                ),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => converting = false);
                          }
                        },
                  child:
                      Text(converting ? 'Converting…' : 'Convert to contract'),
                ),
            ],
          ),
        ),
      ],
    );
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
                if (status == _recordSignatureAction) {
                  await _recordSignature(context, ref);
                  return;
                }
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
                const PopupMenuItem(
                  value: _recordSignatureAction,
                  child: Text('Record client signature…'),
                ),
                // Signed states are reachable only through the signature action above, which
                // keeps the evidence; the database refuses them as plain status updates.
                for (final status in CrmContract.statuses)
                  if (status != contract.status &&
                      !CrmContract.signedStatuses.contains(status))
                    PopupMenuItem(value: status, child: Text(status)),
              ],
            )
          : null,
    );
  }

  static const _recordSignatureAction = '__record_signature';

  Future<void> _recordSignature(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_SignatureInput>(
      context: context,
      builder: (_) => const _RecordSignatureDialog(),
    );
    if (result == null || !context.mounted) return;
    try {
      await ref.read(crmRepositoryProvider).recordContractSignature(
            contractId: contract.id,
            signerName: result.name,
            fullySigned: result.fullySigned,
            note: result.note,
          );
      ref.invalidate(crmContractsProvider(venueId));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not record the signature.')),
        );
      }
    }
  }
}

class _SignatureInput {
  const _SignatureInput({
    required this.name,
    required this.fullySigned,
    this.note,
  });

  final String name;
  final bool fullySigned;
  final String? note;
}

/// Owns its text controllers so they are disposed only after the dialog route has finished
/// animating away (disposing them right after pop trips "used after being disposed").
class _RecordSignatureDialog extends StatefulWidget {
  const _RecordSignatureDialog();

  @override
  State<_RecordSignatureDialog> createState() => _RecordSignatureDialogState();
}

class _RecordSignatureDialogState extends State<_RecordSignatureDialog> {
  final _name = TextEditingController();
  final _note = TextEditingController();
  var _fullySigned = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = "Enter the signer's full name.");
      return;
    }
    final note = _note.text.trim();
    Navigator.of(context).pop(
      _SignatureInput(
        name: name,
        fullySigned: _fullySigned,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record client signature'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Confirm the client has signed this contract. The terms are frozen '
            'and your name, the time and a fingerprint of the terms are kept as evidence.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Signer full name',
              errorText: _error,
            ),
          ),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note (optional, e.g. signed in person)',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _fullySigned,
            onChanged: (value) => setState(() => _fullySigned = value ?? true),
            title: const Text('All parties have signed'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Record signature'),
        ),
      ],
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
