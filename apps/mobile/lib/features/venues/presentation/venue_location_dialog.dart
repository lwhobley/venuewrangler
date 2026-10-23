import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../../core/widgets/dialog_save_button.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../data/venue_location_repository.dart';

class VenueLocationDialog extends ConsumerStatefulWidget {
  const VenueLocationDialog({super.key, required this.venueId});
  final String venueId;
  @override
  ConsumerState<VenueLocationDialog> createState() =>
      _VenueLocationDialogState();
}

class _VenueLocationDialogState extends ConsumerState<VenueLocationDialog> {
  final address = TextEditingController();
  final lat = TextEditingController();
  final lng = TextEditingController();
  final radius = TextEditingController(text: '150');
  @override
  void dispose() {
    for (final c in [address, lat, lng, radius]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Venue location'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Set the venue entrance and clock-in radius. Staff cannot start a punch until a location is set. Only use your current location while at the venue.',
              ),
              TextField(
                controller: address,
                decoration: const InputDecoration(labelText: 'Street address'),
                maxLength: 500,
              ),
              TextField(
                controller: lat,
                decoration: const InputDecoration(labelText: 'Latitude'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              ),
              TextField(
                controller: lng,
                decoration: const InputDecoration(labelText: 'Longitude'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.my_location),
                label: const Text('Use my location at the venue'),
                onPressed: () async {
                  try {
                    final fix =
                        await ref.read(locationServiceProvider).currentFix();
                    if (!mounted) return;
                    lat.text = fix.lat.toString();
                    lng.text = fix.lng.toString();
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not get location. Enter coordinates manually or enable location access.',
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
              TextField(
                controller: radius,
                decoration: const InputDecoration(
                  labelText: 'Clock-in radius (metres, 25-1000)',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          DialogSaveButton(
            label: 'Save location',
            validate: () {
              final a = double.tryParse(lat.text);
              final b = double.tryParse(lng.text);
              final c = int.tryParse(radius.text);
              return address.text.trim().isEmpty ||
                      a == null ||
                      !a.isFinite ||
                      a.abs() > 90 ||
                      b == null ||
                      !b.isFinite ||
                      b.abs() > 180 ||
                      c == null ||
                      c < 25 ||
                      c > 1000 ||
                      (a == 0 && b == 0)
                  ? 'Enter an address, valid coordinates and a radius of 25-1000 metres.'
                  : null;
            },
            save: () =>
                VenueLocationRepository(ref.read(supabaseClientProvider)).save(
              widget.venueId,
              address.text.trim(),
              double.parse(lat.text),
              double.parse(lng.text),
              int.parse(radius.text),
            ),
          ),
        ],
      );
}
