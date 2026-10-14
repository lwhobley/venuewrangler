import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../crm/domain/crm_beo.dart';
import '../../venues/application/venues_providers.dart';
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
    final plans =
        ref.watch(venueFloorPlansProvider(beo.venueId)).valueOrNull ?? const [];
    final layouts = layoutsAsync.valueOrNull ?? const <FloorStudioLayout>[];
    final canManage =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;

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
    // The dropdown only offers plans that have a saved layout, so the selection
    // and the default must come from that same set.
    final layoutPlanIds = {for (final l in layouts) l.floorPlanId};
    final selectedId = layoutPlanIds.contains(_selectedFloorPlanId)
        ? _selectedFloorPlanId
        : layoutPlanIds.contains(defaultPlanId)
            ? defaultPlanId
            : layouts.firstOrNull?.floorPlanId;
    final layout =
        layouts.where((l) => l.floorPlanId == selectedId).firstOrNull;
    final studioLocation = Uri(
      path: '/floor/studio',
      queryParameters: {
        'venue': beo.venueId,
        if (selectedId != null) 'plan': selectedId,
      },
    ).toString();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child:
                      Text('Room preview', style: theme.textTheme.titleLarge),
                ),
                if (canManage && layouts.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => context.push(studioLocation),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit in studio'),
                  ),
              ],
            ),
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
            if (layoutsAsync.hasError && !layoutsAsync.hasValue)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Could not load room layouts: ${layoutsAsync.error}',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(floorStudioLayoutsProvider(beo.venueId)),
                    child: const Text('Retry'),
                  ),
                ],
              )
            else if (layoutsAsync.isLoading && !layoutsAsync.hasValue)
              const LinearProgressIndicator()
            else if (layouts.isEmpty)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'No room layout saved yet. Measure a floor plan in the studio first.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.push(studioLocation),
                    child: const Text('Open studio'),
                  ),
                ],
              )
            else ...[
              DropdownButtonFormField<String>(
                key: ValueKey(selectedId),
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
              if (layout?.loadError != null)
                Text(
                  layout!.loadError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (layout != null &&
                  layout.loadError == null &&
                  guests != null &&
                  layout.capacity < guests)
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
                onPressed: layout == null || layout.loadError != null
                    ? null
                    : () => setState(() => _show3D = !_show3D),
                icon: const Icon(Icons.view_in_ar_outlined),
                label: Text(_show3D ? 'Hide 3D preview' : 'Show 3D preview'),
              ),
              if (_show3D &&
                  layout != null &&
                  layout.loadError == null &&
                  guests != null) ...[
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
