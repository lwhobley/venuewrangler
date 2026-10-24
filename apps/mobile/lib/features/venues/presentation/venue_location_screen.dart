import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../application/venues_providers.dart';
import '../domain/venue_location.dart';

/// Where the active venue is, for the time clock's location check. Managers only (the
/// server enforces it); staff cannot clock in until this is set.
class VenueLocationScreen extends ConsumerStatefulWidget {
  const VenueLocationScreen({super.key});

  @override
  ConsumerState<VenueLocationScreen> createState() =>
      _VenueLocationScreenState();
}

class _VenueLocationScreenState extends ConsumerState<VenueLocationScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _address;
  late final TextEditingController _coordinates;
  late int _radius;
  bool _locating = false;
  bool _saving = false;
  String? _fixNote;
  String? _error;

  @override
  void initState() {
    super.initState();
    final venue = ref.read(activeVenueProvider);
    _address = TextEditingController(text: venue?.address ?? '');
    _coordinates = TextEditingController(
      text: venue != null && venue.hasLocation
          ? formatCoordinates(venue.latitude!, venue.longitude!)
          : '',
    );
    _radius = kGeofenceRadiusOptions.contains(venue?.geofenceRadiusM)
        ? venue!.geofenceRadiusM
        : 100;
  }

  @override
  void dispose() {
    _address.dispose();
    _coordinates.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _fixNote = null;
      _error = null;
    });
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      if (!mounted) return;
      setState(() {
        _coordinates.text = formatCoordinates(fix.lat, fix.lng);
        _fixNote = fix.accuracyM > 50
            ? 'This reading is only accurate to about ${fix.accuracyM.round()} m. '
                'Stand inside the venue and try again, or enter the coordinates.'
            : 'Accurate to about ${fix.accuracyM.round()} m. Make sure you are at the venue.';
      });
    } on PermissionDeniedError {
      if (mounted) {
        setState(
          () => _error =
              'Allow location access to use your current location, or enter the coordinates.',
        );
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    final venue = ref.read(activeVenueProvider);
    final coords = parseCoordinates(_coordinates.text);
    if (venue == null || coords == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await ref.read(venuesRepositoryProvider).setVenueLocation(
            venueId: venue.id,
            latitude: coords.latitude,
            longitude: coords.longitude,
            geofenceRadiusM: _radius,
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
          );
      if (!mounted) return;
      // Only replace the active venue if the person has not switched away meanwhile.
      if (ref.read(activeVenueProvider)?.id == updated.id) {
        ref.read(activeVenueProvider.notifier).state = updated;
      }
      ref.invalidate(venuesForOrganizationProvider(updated.organizationId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Venue location saved. Clock-ins are now checked.'),
        ),
      );
      Navigator.of(context).maybePop();
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.code == '42501'
              ? 'Only managers of this venue can change its location.'
              : e.code == '22023'
                  ? e.message
                  : 'Could not save the location. Try again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save the location. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    final theme = Theme.of(context);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Venue location')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Staff can only clock in within the area you set here. Until a '
              'location is saved, clock-in is unavailable at ${venue.name}.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _address,
              maxLength: 300,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '123 Main St, Chicago, IL',
                helperText:
                    'Shown to your team. It is not used to find the map '
                    'position, so set the position below too.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('venue-coordinates'),
              controller: _coordinates,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Map position (latitude, longitude)',
                hintText: '41.878100, -87.629800',
                helperText: 'Copy it from a map app, or use your current '
                    'location while you are at the venue.',
                helperMaxLines: 2,
              ),
              validator: (value) => parseCoordinates(value ?? '') == null
                  ? 'Enter a latitude and longitude, e.g. 41.8781, -87.6298'
                  : null,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _locating ? null : _useCurrentLocation,
                icon: _locating
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
                label: const Text('Use my current location'),
              ),
            ),
            if (_fixNote != null) ...[
              const SizedBox(height: 8),
              Text(_fixNote!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 20),
            DropdownButtonFormField<int>(
              initialValue: _radius,
              decoration: const InputDecoration(
                labelText: 'Clock-in radius',
                helperText: 'How far from the map position a punch may be.',
              ),
              items: [
                for (final r in kGeofenceRadiusOptions)
                  DropdownMenuItem(value: r, child: Text('$r m')),
              ],
              onChanged: (value) => setState(() => _radius = value ?? _radius),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.ops.danger.bg,
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.ops.danger.fg),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save location'),
            ),
          ],
        ),
      ),
    );
  }
}
