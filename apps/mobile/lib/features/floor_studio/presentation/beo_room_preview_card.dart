import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../crm/domain/crm_beo.dart';
import '../../floor/application/floor_providers.dart';
import '../application/floor_studio_providers.dart';
import '../domain/floor_studio.dart';
import 'floor_studio_3d_view.dart';

/// 3D room preview for a banquet order. The guest count comes from the confirmed BEO. A BEO
/// that isn't confirmed yet falls back to the headcount on its reservation. A mismatch
/// between the two is flagged, and so is a saved layout that can't seat the guests.
class BeoRoomPreviewCard extends ConsumerStatefulWidget {
  const BeoRoomPreviewCard({super.key, required this.beo});

  final CrmBeo beo;

  @override
  ConsumerState<BeoRoomPreviewCard> createState() => _BeoRoomPreviewCardState();
}

class _BeoRoomPreviewCardState extends ConsumerState<BeoRoomPreviewCard> {
  String? _selectedFloorPlanId;
  var _show3D = false;

  @override
  Widget build(BuildContext context) {
    final beo = widget.beo;
    final theme = Theme.of(context);
    final layoutsAsync = ref.watch(floorStudioLayoutsProvider(beo.venueId));
    final partySizeAsync = ref.watch(beoReservationPartySizeProvider(beo.id));
    final plans = ref.watch(floorPlansProvider).valueOrNull ?? const [];
    final layouts = layoutsAsync.valueOrNull ?? const <FloorStudioLayout>[];

    final confirmed = beo.status == 'confirmed';
    final reservationGuests = partySizeAsync.valueOrNull;
    final guests =
        confirmed ? beo.guestCount : (reservationGuests ?? beo.guestCount);
    final guestsDiffer = confirmed &&
        reservationGuests != null &&
        beo.guestCount != null &&
        reservationGuests != beo.guestCount;

    final venueSpace = beo.venueSpace?.trim().toLowerCase();
    final defaultPlanId = plans
        .where(
          (p) =>
              venueSpace != null && p.name.trim().toLowerCase() == venueSpace,
        )
        .map((p) => p.id)
        .firstOrNull;
    final selectedId = layouts.any((l) => l.floorPlanId == _selectedFloorPlanId)
        ? _selectedFloorPlanId
        : (defaultPlanId ?? layouts.firstOrNull?.floorPlanId);
    final layout =
        layouts.where((l) => l.floorPlanId == selectedId).firstOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Room preview', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (guests == null)
              const Text('No guest count set for this order yet.')
            else
              Text(
                confirmed
                    ? 'Seating $guests guests from the confirmed order.'
                    : reservationGuests != null
                        ? 'Order not confirmed yet. Seating $reservationGuests guests from the reservation.'
                        : 'Order not confirmed yet. Seating ${beo.guestCount} guests from the order.',
                style: theme.textTheme.bodySmall,
              ),
            if (guestsDiffer)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'The reservation headcount ($reservationGuests) does not match the confirmed order '
                  '(${beo.guestCount}). Showing the order count.',
                  style: TextStyle(color: Colors.amber.shade900),
                ),
              ),
            const SizedBox(height: 12),
            if (layouts.isEmpty)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'No room layout saved yet. Measure a floor plan in the studio first.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.push('/floor/studio'),
                    child: const Text('Open studio'),
                  ),
                ],
              )
            else ...[
              DropdownButtonFormField<String>(
                initialValue: selectedId,
                decoration: const InputDecoration(labelText: 'Room layout'),
                items: [
                  for (final l in layouts)
                    DropdownMenuItem(
                      value: l.floorPlanId,
                      child: Text(
                        plans
                                .where((p) => p.id == l.floorPlanId)
                                .firstOrNull
                                ?.name ??
                            'Floor plan',
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _selectedFloorPlanId = value),
              ),
              if (layout != null && guests != null && layout.capacity < guests)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'This room layout seats up to ${layout.capacity} guests, fewer than the $guests expected.',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: layout == null
                    ? null
                    : () => setState(() => _show3D = !_show3D),
                icon: const Icon(Icons.view_in_ar_outlined),
                label: Text(_show3D ? 'Hide 3D preview' : 'Show 3D preview'),
              ),
              if (_show3D && layout != null && guests != null) ...[
                const SizedBox(height: 10),
                FloorStudio3DView(
                  sceneData:
                      buildStudioSceneData(layout: layout, guestCount: guests),
                ),
                const SizedBox(height: 6),
                const Text(
                  '3D preview is an illustrative render of this layout, not a photograph. '
                  'People and food are stylized placeholders, not the actual guests or menu.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
