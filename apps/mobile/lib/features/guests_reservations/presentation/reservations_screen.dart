import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../venues/application/venues_providers.dart';
import '../application/guests_reservations_providers.dart';
import '../domain/reservation.dart';

class ReservationsScreen extends ConsumerStatefulWidget {
  const ReservationsScreen({super.key});

  @override
  ConsumerState<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends ConsumerState<ReservationsScreen> {
  String _statusFilter = 'all';

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
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
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
                final filtered = _statusFilter == 'all'
                    ? reservations
                    : reservations.where((r) => r.status == _statusFilter).toList();

                if (filtered.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.event_seat, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No reservations found',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async => ref.refresh(reservationsListProvider.future),
                  child: ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      return _ReservationListTile(
                        reservation: item,
                        onStatusChanged: (newStatus) async {
                          await ref
                              .read(guestsReservationsRepositoryProvider)
                              .updateReservationStatus(
                                reservationId: item.id,
                                status: newStatus,
                              );
                          ref.invalidate(reservationsListProvider);
                        },
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 8),
                    Text('Failed to load reservations: $err', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => ref.invalidate(reservationsListProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: activeVenue != null
          ? FloatingActionButton(
              onPressed: () => _showCreateReservationDialog(context, activeVenue.id),
              tooltip: 'New Reservation',
              child: const Icon(Icons.add),
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

  Future<void> _showCreateReservationDialog(BuildContext context, String venueId) async {
    final nameCtrl = TextEditingController();
    final partyCtrl = TextEditingController(text: '2');
    final phoneCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final requestsCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
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
                decoration: const InputDecoration(labelText: 'Special Requests'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final party = int.tryParse(partyCtrl.text.trim()) ?? 2;
              if (name.isEmpty) return;

              await ref.read(guestsReservationsRepositoryProvider).createReservation(
                    venueId: venueId,
                    guestName: name,
                    partySize: party,
                    guestPhone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
                    guestEmail: emailCtrl.text.trim().isEmpty ? null : emailCtrl.text.trim(),
                    specialRequests:
                        requestsCtrl.text.trim().isEmpty ? null : requestsCtrl.text.trim(),
                    reservationTime: DateTime.now().add(const Duration(hours: 1)),
                  );
              if (mounted) {
                Navigator.of(dialogCtx).pop();
                ref.invalidate(reservationsListProvider);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class _ReservationListTile extends StatelessWidget {
  const _ReservationListTile({
    required this.reservation,
    required this.onStatusChanged,
  });

  final Reservation reservation;
  final ValueChanged<String> onStatusChanged;

  Color _statusColor(BuildContext context, String status) {
    switch (status) {
      case 'confirmed':
        return Colors.green;
      case 'seated':
        return Colors.blue;
      case 'completed':
        return Colors.grey;
      case 'cancelled':
      case 'no_show':
        return Colors.red;
      default:
        return Colors.orange;
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
          if (reservation.specialRequests != null && reservation.specialRequests!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2.0),
              child: Text(
                'Note: ${reservation.specialRequests}',
                style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(
            label: Text(
              reservation.status.toUpperCase(),
              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            backgroundColor: _statusColor(context, reservation.status),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: onStatusChanged,
            itemBuilder: (context) => [
              if (reservation.status != 'seated')
                const PopupMenuItem(value: 'seated', child: Text('Seat')),
              if (reservation.status != 'completed')
                const PopupMenuItem(value: 'completed', child: Text('Complete')),
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
