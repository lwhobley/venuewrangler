import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_chip.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/application/workforce_providers.dart';
import '../../workforce/domain/workforce_models.dart';
import '../application/guests_reservations_providers.dart';
import '../domain/reservation.dart';

class ReservationsScreen extends ConsumerStatefulWidget {
  const ReservationsScreen({super.key});

  @override
  ConsumerState<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends ConsumerState<ReservationsScreen> {
  String _statusFilter = 'all';

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
    if (picked == null || picked.userId == r.assignedTo) return;
    await ref
        .read(guestsReservationsRepositoryProvider)
        .assignReservation(reservationId: r.id, userId: picked.userId);
    ref.invalidate(reservationsListProvider);
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
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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
                final filtered = _statusFilter == 'all'
                    ? reservations
                    : reservations
                        .where((r) => r.status == _statusFilter)
                        .toList();

                if (filtered.isEmpty) {
                  return const EmptyState(
                    icon: Icons.event_seat,
                    message: 'No reservations found',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async =>
                      ref.refresh(reservationsListProvider.future),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      return Card(
                        child: _ReservationListTile(
                          reservation: item,
                          assigneeName: item.assignedTo == null
                              ? null
                              : names[item.assignedTo] ?? 'Team member',
                          onAssign: () => _assign(item, roster),
                          onStatusChanged: (newStatus) async {
                            await ref
                                .read(guestsReservationsRepositoryProvider)
                                .updateReservationStatus(
                                  reservationId: item.id,
                                  status: newStatus,
                                );
                            ref.invalidate(reservationsListProvider);
                          },
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
                  onPressed: () =>
                      _showCreateReservationDialog(context, activeVenue.id),
                  label: const Text('New Reservation'),
                  icon: const Icon(Icons.add),
                ),
              ),
            )
          : null,
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
  ) async {
    final nameCtrl = TextEditingController();
    final partyCtrl = TextEditingController(text: '2');
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final requestsCtrl = TextEditingController();
    var reservationTime = DateTime.now().add(const Duration(hours: 1));
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
                    MaterialLocalizations.of(dialogCtx)
                        .formatMediumDate(reservationTime),
                  ),
                  trailing: Text(
                    MaterialLocalizations.of(dialogCtx).formatTimeOfDay(
                      TimeOfDay.fromDateTime(reservationTime),
                    ),
                  ),
                  onTap: saving
                      ? null
                      : () async {
                          final date = await showDatePicker(
                            context: dialogCtx,
                            initialDate: reservationTime,
                            firstDate: DateTime.now(),
                            lastDate:
                                DateTime.now().add(const Duration(days: 365)),
                          );
                          if (date == null || !dialogCtx.mounted) return;
                          final time = await showTimePicker(
                            context: dialogCtx,
                            initialTime:
                                TimeOfDay.fromDateTime(reservationTime),
                          );
                          if (time == null || !dialogCtx.mounted) return;
                          update(() {
                            reservationTime = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              time.hour,
                              time.minute,
                            );
                          });
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
                      if (name.isEmpty ||
                          party == null ||
                          party < 1 ||
                          reservationTime.isBefore(DateTime.now())) {
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
                              reservationTime: reservationTime,
                            );
                        if (dialogCtx.mounted) {
                          Navigator.of(dialogCtx).pop();
                          ref.invalidate(reservationsListProvider);
                        }
                      } catch (_) {
                        if (dialogCtx.mounted) {
                          update(() {
                            validationError =
                                'Could not create the reservation. Please try again.';
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
    nameCtrl.dispose();
    partyCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
    requestsCtrl.dispose();
  }
}

class _ReservationListTile extends StatelessWidget {
  const _ReservationListTile({
    required this.reservation,
    required this.onStatusChanged,
    this.assigneeName,
    this.onAssign,
  });

  final Reservation reservation;
  final ValueChanged<String> onStatusChanged;
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
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Text(
        reservation.guestName,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            'Time: ${_formatTime(reservation.reservationTime)} | Source: ${reservation.source}',
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
                style:
                    const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
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
            onSelected: (value) =>
                value == 'assign' ? onAssign?.call() : onStatusChanged(value),
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
                const PopupMenuItem(value: 'cancelled', child: Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $ampm';
  }
}
