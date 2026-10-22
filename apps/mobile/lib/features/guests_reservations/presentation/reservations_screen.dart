import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_chip.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/domain/venue_timezone.dart';
import '../../venues/presentation/venue_time_widgets.dart';
import '../../workforce/application/workforce_providers.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/guests_reservations_providers.dart';
import '../domain/hold_conflict.dart';
import '../domain/reservation.dart';
import '../domain/reservation_book.dart';

/// Turns a failed reservation write into a message the person can act on; anything unexpected
/// keeps the caller's generic [fallback]. The hold triggers raise 23505
/// `reservation_hold_conflict` with the bookings in the way in DETAIL, and the private-event
/// sync (20261022130000_beo_cancel_restore_and_hold_sync.sql) raises 42501
/// `beo_hold_managed_in_crm` and 22023 `beo_restore_past`.
String _reservationWriteErrorMessage(
  Object error, {
  required String fallback,
  required VenueClock clock,
}) {
  if (error is! PostgrestException) return fallback;
  if (error.code == '23505' && isHoldConflictMessage(error.message)) {
    return describeHoldConflict(
      HoldConflict.parse(error.details),
      clock,
      subject: 'This time',
    );
  }
  if (error.message.contains('beo_hold_managed_in_crm')) {
    if (error.message.contains('ask a manager')) {
      return 'This booking holds a private event. Ask a manager to change '
          'the event in CRM.';
    }
    return 'This booking holds a private event. Change the event in CRM '
        'instead.';
  }
  if (error.message.contains('beo_restore_past')) {
    return "This private event's date has passed, so it can't be restored.";
  }
  return fallback;
}

class ReservationsScreen extends ConsumerStatefulWidget {
  const ReservationsScreen({super.key});

  @override
  ConsumerState<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends ConsumerState<ReservationsScreen> {
  String _statusFilter = 'all';
  String _dateFilter = 'all';
  final Set<String> _savingReservationIds = {};

  Future<void> _assign(Reservation r, List<RosterMember> roster) async {
    final picked = await showModalBottomSheet<({String? userId})>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Assign ${r.guestName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_off_outlined),
              title: const Text('Unassigned'),
              selected: r.assignedTo == null,
              onTap: () => Navigator.pop(context, (userId: null)),
            ),
            for (final m in roster)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(m.displayName ?? 'Team member'),
                selected: r.assignedTo == m.userId,
                onTap: () => Navigator.pop(context, (userId: m.userId)),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null || picked.userId == r.assignedTo) return;
    await _runReservationMutation(
      r.id,
      () => ref
          .read(guestsReservationsRepositoryProvider)
          .assignReservation(reservationId: r.id, userId: picked.userId),
    );
  }

  Future<void> _updateStatus(Reservation r, String status) async {
    final changesEvent = r.isPrivateEventHold &&
        (status == 'cancelled' || r.status == 'cancelled');
    final restoring = status != 'cancelled';
    if (changesEvent &&
        !await _confirmPrivateEventChange(r, restoring: restoring)) {
      return;
    }
    await _runReservationMutation(
      r.id,
      () => ref
          .read(guestsReservationsRepositoryProvider)
          .updateReservationStatus(reservationId: r.id, status: status),
    );
  }

  /// Cancelling or restoring a private event's booking does the same to the event, so say so
  /// (and who may do it) before anything is sent.
  Future<bool> _confirmPrivateEventChange(
    Reservation r, {
    required bool restoring,
  }) async {
    final clock = ref.read(venueClockProvider);
    final summary = '${r.guestName} · ${r.partySize} guests · '
        '${clock.formatDateTime(r.reservationTime)}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          restoring
              ? 'Restore this private event?'
              : 'Cancel this private event?',
        ),
        content: Text(
          restoring
              ? '$summary\n\nThis booking holds a private event. Restoring it '
                  'restores the event and holds the venue again, if that time is '
                  'still free. Only a manager can do this.'
              : '$summary\n\nThis booking holds a private event. Cancelling it '
                  'also cancels the event in CRM and opens the night to other '
                  'bookings. Only a manager can do this; a manager can restore it '
                  'before the event date if the time is still free.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(restoring ? 'Not now' : 'Keep event'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(restoring ? 'Restore event' : 'Cancel event'),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  Future<void> _runReservationMutation(
    String reservationId,
    Future<void> Function() mutation,
  ) async {
    if (!mounted || !_savingReservationIds.add(reservationId)) return;
    setState(() {});
    try {
      await mutation();
      if (mounted) ref.invalidate(reservationsListProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _reservationWriteErrorMessage(
                error,
                fallback: 'Could not update this reservation. Try again.',
                clock: ref.read(venueClockProvider),
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _savingReservationIds.remove(reservationId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reservationsAsync = ref.watch(reservationsListProvider);
    final activeVenue = ref.watch(activeVenueProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reservations'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(reservationsListProvider),
          ),
        ],
      ),
      body: Column(
        children: [
          const UnsupportedTimezoneBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 4.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildDateFilterChip('All Dates', 'all'),
                  const SizedBox(width: 8),
                  _buildDateFilterChip('Today', 'today'),
                  const SizedBox(width: 8),
                  _buildDateFilterChip('Tomorrow', 'tomorrow'),
                  const SizedBox(width: 8),
                  _buildDateFilterChip('This Week', 'week'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 8.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildFilterChip('All', 'all'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Confirmed', 'confirmed'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Seated', 'seated'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Completed', 'completed'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Cancelled', 'cancelled'),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: reservationsAsync.when(
              data: (reservations) {
                final roster = activeVenue == null
                    ? const <RosterMember>[]
                    : ref
                            .watch(rosterForVenueProvider(activeVenue.id))
                            .valueOrNull ??
                        const <RosterMember>[];
                final names = {
                  for (final m in roster)
                    m.userId: m.displayName ?? 'Team member',
                };
                final tz = activeVenue?.timezone ?? 'UTC';
                final today = VenueTimezone.businessDateFor(DateTime.now(), tz);
                final tomorrow =
                    DateTime.utc(today.year, today.month, today.day + 1);
                final weekEnd =
                    DateTime.utc(today.year, today.month, today.day + 7);

                final dateFiltered = reservations.where((r) {
                  if (_dateFilter == 'all') return true;
                  final rDate =
                      VenueTimezone.businessDateFor(r.reservationTime, tz);
                  if (_dateFilter == 'today') {
                    return rDate.year == today.year &&
                        rDate.month == today.month &&
                        rDate.day == today.day;
                  } else if (_dateFilter == 'tomorrow') {
                    return rDate.year == tomorrow.year &&
                        rDate.month == tomorrow.month &&
                        rDate.day == tomorrow.day;
                  } else if (_dateFilter == 'week') {
                    return !rDate.isBefore(today) && rDate.isBefore(weekEnd);
                  }
                  return true;
                }).toList();

                final filtered = _statusFilter == 'all'
                    ? dateFiltered
                    : dateFiltered
                        .where((r) => r.status == _statusFilter)
                        .toList();

                if (filtered.isEmpty) {
                  return const EmptyState(
                    icon: Icons.event_seat,
                    message: 'No reservations found',
                  );
                }

                // One entry per row: a night header (reservation == null) or a booking.
                final rows = <({DateTime night, Reservation? reservation})>[
                  for (final night in reservationBook(
                    filtered,
                    tz,
                    today: today,
                  )) ...[
                    (night: night.night, reservation: null),
                    for (final r in night.reservations)
                      (night: night.night, reservation: r),
                  ],
                ];

                return RefreshIndicator(
                  onRefresh: () async =>
                      ref.refresh(reservationsListProvider.future),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final item = row.reservation;
                      if (item == null) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                          child: Row(
                            children: [
                              Icon(
                                Icons.calendar_today,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                formatNight(row.night),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                              ),
                            ],
                          ),
                        );
                      }
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: _ReservationListTile(
                          reservation: item,
                          timezone: tz,
                          busy: _savingReservationIds.contains(item.id),
                          assigneeName: item.assignedTo == null
                              ? null
                              : names[item.assignedTo] ?? 'Team member',
                          onAssign: () => _assign(item, roster),
                          onStatusChanged: (newStatus) =>
                              _updateStatus(item, newStatus),
                        ),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => ErrorState(
                message: 'Failed to load reservations: $err',
                onRetry: () => ref.invalidate(reservationsListProvider),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: activeVenue != null
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => _showCreateReservationDialog(
                    context,
                    activeVenue.id,
                    activeVenue.timezone,
                  ),
                  label: const Text('New Reservation'),
                  icon: const Icon(Icons.add),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildDateFilterChip(String label, String value) {
    final isSelected = _dateFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _dateFilter = value);
        }
      },
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _statusFilter = value);
        }
      },
    );
  }

  Future<void> _showCreateReservationDialog(
    BuildContext context,
    String venueId,
    String timezone,
  ) async {
    final clock = VenueClock(timezone);
    if (!ensureSupported(context, clock)) return;
    final nameCtrl = TextEditingController();
    final partyCtrl = TextEditingController(text: '2');
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final requestsCtrl = TextEditingController();
    // A venue wall time (UTC-flagged, fields = the venue's clock), shown as-is and converted to
    // an instant only when saved.
    var reservationTime = clock.now.add(const Duration(hours: 1));
    var saving = false;
    String? validationError;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, update) => AlertDialog(
          title: const Text('New Reservation'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Guest Name *'),
                ),
                TextField(
                  controller: partyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Party Size *'),
                ),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                TextField(
                  controller: requestsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Special Requests',
                  ),
                ),
                ListTile(
                  title: const Text('Date and time'),
                  subtitle: Text(
                    VenueTimezone.formatWallDate(reservationTime),
                  ),
                  trailing: Text(
                    VenueTimezone.formatWallTime(reservationTime),
                  ),
                  onTap: saving
                      ? null
                      : () async {
                          final picked = await pickVenueDateTime(
                            dialogCtx,
                            initial: reservationTime,
                            nowWall: clock.now,
                          );
                          if (picked == null || !dialogCtx.mounted) return;
                          update(() => reservationTime = picked);
                        },
                ),
                if (validationError != null)
                  Text(
                    validationError!,
                    style: TextStyle(
                      color: Theme.of(dialogCtx).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(dialogCtx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      final name = nameCtrl.text.trim();
                      final party = int.tryParse(partyCtrl.text.trim());
                      final reservationUtc = clock.instant(reservationTime);
                      if (name.isEmpty ||
                          party == null ||
                          party < 1 ||
                          reservationUtc.isBefore(DateTime.now().toUtc())) {
                        update(() {
                          validationError =
                              'Enter a guest, a valid party size, and a future time.';
                        });
                        return;
                      }
                      update(() {
                        saving = true;
                        validationError = null;
                      });
                      try {
                        await ref
                            .read(guestsReservationsRepositoryProvider)
                            .createReservation(
                              venueId: venueId,
                              guestName: name,
                              partySize: party,
                              guestPhone: phoneCtrl.text.trim().isEmpty
                                  ? null
                                  : phoneCtrl.text.trim(),
                              guestEmail: emailCtrl.text.trim().isEmpty
                                  ? null
                                  : emailCtrl.text.trim(),
                              specialRequests: requestsCtrl.text.trim().isEmpty
                                  ? null
                                  : requestsCtrl.text.trim(),
                              reservationTime: reservationUtc,
                            );
                        if (dialogCtx.mounted) {
                          Navigator.of(dialogCtx).pop();
                          ref.invalidate(reservationsListProvider);
                        }
                      } catch (error) {
                        if (dialogCtx.mounted) {
                          update(() {
                            validationError = _reservationWriteErrorMessage(
                              error,
                              fallback:
                                  'Could not create reservation. Please try again.',
                              clock: clock,
                            );
                          });
                        }
                      } finally {
                        if (dialogCtx.mounted) {
                          update(() => saving = false);
                        }
                      }
                    },
              child: Text(saving ? 'Creating…' : 'Create'),
            ),
          ],
        ),
      ),
    );
    // The controllers are deliberately not disposed here: showDialog completes when the route is
    // popped, but the dialog keeps rebuilding through its exit animation, and a disposed
    // controller throws if a TextField builds with it. Nothing listens to them once the dialog
    // is gone, so they are simply collected.
  }
}

class _ReservationListTile extends StatelessWidget {
  const _ReservationListTile({
    required this.reservation,
    required this.onStatusChanged,
    required this.busy,
    required this.timezone,
    this.assigneeName,
    this.onAssign,
  });

  final Reservation reservation;
  final Future<void> Function(String) onStatusChanged;
  final bool busy;
  final String timezone;
  final String? assigneeName;
  final VoidCallback? onAssign;

  Tone _statusTone(String status) {
    switch (status) {
      case 'confirmed':
        return Tone.success;
      case 'seated':
        return Tone.info;
      case 'completed':
        return Tone.neutral;
      case 'cancelled':
      case 'no_show':
        return Tone.danger;
      default:
        return Tone.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          '${reservation.partySize}p',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
        ),
      ),
      title: Text(
        reservation.guestName,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            'Time: ${VenueTimezone.formatTime(reservation.reservationTime, timezone)} | Source: ${reservation.source}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (assigneeName != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: StatusChip(
                label: assigneeName!,
                tone: Tone.info,
                icon: Icons.person_outline,
                dense: true,
              ),
            ),
          if (reservation.specialRequests != null &&
              reservation.specialRequests!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2.0),
              child: Text(
                'Note: ${reservation.specialRequests}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusChip(
            label: reservation.status.toUpperCase(),
            tone: _statusTone(reservation.status),
            dense: true,
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            enabled: !busy,
            onSelected: (value) {
              if (value == 'assign') {
                onAssign?.call();
              } else {
                unawaited(onStatusChanged(value));
              }
            },
            itemBuilder: (context) => [
              if (onAssign != null)
                const PopupMenuItem(value: 'assign', child: Text('Assign to…')),
              if (reservation.status != 'seated')
                const PopupMenuItem(value: 'seated', child: Text('Seat')),
              if (reservation.status != 'completed')
                const PopupMenuItem(
                  value: 'completed',
                  child: Text('Complete'),
                ),
              if (reservation.status != 'cancelled')
                const PopupMenuItem(value: 'cancelled', child: Text('Cancel'))
              else
                const PopupMenuItem(value: 'confirmed', child: Text('Restore')),
            ],
          ),
        ],
      ),
    );
  }
}
