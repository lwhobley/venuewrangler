import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../guests_reservations/domain/hold_conflict.dart';
import '../../venues/domain/venue_clock.dart';
import '../domain/beo_time.dart';
import '../domain/crm_beo.dart';
import 'crm_beo_detail_screen.dart' show formatBeoMoney;

/// Asks before a BEO is cancelled, naming what is at stake: the event, its date, guests and
/// recorded charges ([chargesCents] is null when they could not be loaded). Returns true only
/// when the manager confirms.
Future<bool> confirmCancelBeo(
  BuildContext context, {
  required CrmBeo beo,
  required VenueClock clock,
  required int? chargesCents,
}) async {
  final facts = [
    if (beo.eventDate != null) beoWhenLabel(beo.eventDate!, clock),
    if (beo.guestCount != null) '${beo.guestCount} guests',
    chargesCents == null
        ? 'charges could not be loaded'
        : '${formatBeoMoney(chargesCents)} in charges',
  ].join(' · ');
  final holdsNight = beo.status == 'confirmed';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Cancel ${beo.eventName}?'),
      content: Text(
        '$facts\n\n'
        '${holdsNight ? 'Its booking in Reservations is cancelled too and the night opens to other bookings. ' : ''}'
        'You can restore it until the event date, as long as the time is still free.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep event'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Cancel event'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// A message for a failed confirm/cancel/restore of a BEO. Hold conflicts name the bookings in
/// the way (ordinary reservations or another event), in the venue's clock.
String beoWriteErrorMessage(Object error, VenueClock clock) {
  final message = error is PostgrestException ? error.message : '$error';
  if (isHoldConflictMessage(message)) {
    return describeHoldConflict(
      HoldConflict.parse(error is PostgrestException ? error.details : null),
      clock,
      subject: 'This event',
    );
  }
  if (message.contains('beo_restore_past')) {
    return "This event's date has passed, so it can't be restored.";
  }
  if (message.contains('beo_not_cancelled')) {
    return 'This event is no longer cancelled. Pull to refresh.';
  }
  return 'Something went wrong. Please try again.';
}
