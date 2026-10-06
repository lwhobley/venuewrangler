import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../venues/application/venues_providers.dart';
import '../application/staff_requests_providers.dart';
import '../domain/staff_request.dart';

class StaffRequestsScreen extends ConsumerWidget {
  const StaffRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(
        body: Center(
          child: Text('No venue selected.'),
        ),
      );
    }

    final requestsAsync = ref.watch(staffRequestsForVenueProvider(venue.id));
    final currentUserId = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Staff Requests — ${venue.name}'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(staffRequestsForVenueProvider(venue.id));
        },
        child: requestsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load staff requests.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(staffRequestsForVenueProvider(venue.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (requests) {
            if (requests.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: const Center(
                      child: Text('No staff requests yet.'),
                    ),
                  ),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: requests.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final request = requests[index];
                return _StaffRequestTile(
                  request: request,
                  isOwner: request.userId == currentUserId,
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateRequestDialog(context, ref, venue.id),
        icon: const Icon(Icons.add),
        label: const Text('New Request'),
      ),
    );
  }

  void _showCreateRequestDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => _CreateStaffRequestDialog(venueId: venueId),
    );
  }
}

class _StaffRequestTile extends ConsumerWidget {
  const _StaffRequestTile({
    required this.request,
    required this.isOwner,
  });

  final StaffRequest request;
  final bool isOwner;

  Tone _statusTone() {
    return switch (request.status) {
      StaffRequestStatus.pending => Tone.warning,
      StaffRequestStatus.approved => Tone.success,
      StaffRequestStatus.denied => Tone.danger,
      StaffRequestStatus.cancelled => Tone.neutral,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusColor = context.ops.of(_statusTone()).fg;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: statusColor.withValues(alpha: 0.15),
        child: Icon(
          _kindIcon(request.kind),
          color: statusColor,
          size: 20,
        ),
      ),
      title: Text(request.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${request.kind.displayLabel} • ${request.status.displayLabel}',
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (request.details.isNotEmpty) Text(request.details),
          if (request.requestedRangeStart != null)
            Text(
              'Dates: ${request.requestedRangeStart}'
              '${request.requestedRangeEnd != null ? ' – ${request.requestedRangeEnd}' : ''}',
            ),
          if (request.responseNotes != null &&
              request.responseNotes!.isNotEmpty)
            Text(
              'Response: ${request.responseNotes}',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: request.isPending
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isOwner)
                  TextButton(
                    onPressed: () => _cancelRequest(context, ref),
                    child: const Text('Cancel'),
                  ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'approve') {
                      _reviewRequest(context, ref, StaffRequestStatus.approved);
                    } else if (action == 'deny') {
                      _reviewRequest(context, ref, StaffRequestStatus.denied);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'approve',
                      child: Text('Approve'),
                    ),
                    const PopupMenuItem(
                      value: 'deny',
                      child: Text('Deny'),
                    ),
                  ],
                ),
              ],
            )
          : null,
    );
  }

  IconData _kindIcon(StaffRequestKind kind) {
    return switch (kind) {
      StaffRequestKind.addShift => Icons.add_circle_outline,
      StaffRequestKind.dropShift => Icons.remove_circle_outline,
      StaffRequestKind.timeOff => Icons.beach_access_outlined,
      StaffRequestKind.shiftSwap => Icons.swap_horiz_outlined,
      StaffRequestKind.openShift => Icons.event_available_outlined,
      StaffRequestKind.sickLeave => Icons.healing_outlined,
      StaffRequestKind.timeCorrection => Icons.access_time_outlined,
      StaffRequestKind.other => Icons.help_outline,
    };
  }

  Future<void> _cancelRequest(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(staffRequestsRepositoryProvider).cancelRequest(request.id);
      ref.invalidate(staffRequestsForVenueProvider(request.venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? 'You do not have permission to cancel this request.'
          : 'Could not cancel request. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _reviewRequest(
    BuildContext context,
    WidgetRef ref,
    StaffRequestStatus status,
  ) async {
    final notesController = TextEditingController();
    final shouldProceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${status.displayLabel} Request'),
        content: TextField(
          controller: notesController,
          decoration: const InputDecoration(
            labelText: 'Response notes (optional)',
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(status.displayLabel),
          ),
        ],
      ),
    );

    if (shouldProceed != true) return;
    if (!context.mounted) return;

    try {
      await ref.read(staffRequestsRepositoryProvider).reviewRequest(
            requestId: request.id,
            status: status,
            responseNotes: notesController.text.trim(),
          );
      ref.invalidate(staffRequestsForVenueProvider(request.venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? 'You do not have permission to review staff requests.'
          : 'Could not review request. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }
}

class _CreateStaffRequestDialog extends ConsumerStatefulWidget {
  const _CreateStaffRequestDialog({required this.venueId});

  final String venueId;

  @override
  ConsumerState<_CreateStaffRequestDialog> createState() =>
      _CreateStaffRequestDialogState();
}

class _CreateStaffRequestDialogState
    extends ConsumerState<_CreateStaffRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  StaffRequestKind _kind = StaffRequestKind.timeOff;
  final _titleController = TextEditingController();
  final _detailsController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;
  bool _submitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = (isStart ? _startDate : _endDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    try {
      await ref.read(staffRequestsRepositoryProvider).createRequest(
            venueId: widget.venueId,
            kind: _kind,
            title: _titleController.text.trim(),
            details: _detailsController.text.trim(),
            requestedRangeStart:
                _startDate == null ? null : _formatDate(_startDate!),
            requestedRangeEnd: _endDate == null ? null : _formatDate(_endDate!),
          );
      if (!mounted) return;
      ref.invalidate(staffRequestsForVenueProvider(widget.venueId));
      Navigator.of(context).pop();
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      final message = error.code == '42501'
          ? 'You do not have permission to submit requests for this venue.'
          : 'Could not submit request. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Staff Request'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<StaffRequestKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Request Type'),
                items: StaffRequestKind.values.map((k) {
                  return DropdownMenuItem(
                    value: k,
                    child: Text(k.displayLabel),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _kind = val);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'e.g. Time off for doctor appointment',
                ),
                validator: (val) => (val == null || val.trim().isEmpty)
                    ? 'Title is required'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _detailsController,
                decoration: const InputDecoration(
                  labelText: 'Details (optional)',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start date (optional)'),
                subtitle: Text(
                  _startDate == null ? 'Not set' : _formatDate(_startDate!),
                ),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () => _pickDate(isStart: true),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('End date (optional)'),
                subtitle:
                    Text(_endDate == null ? 'Not set' : _formatDate(_endDate!)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () => _pickDate(isStart: false),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}
