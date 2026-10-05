import 'package:geolocator/geolocator.dart';

import '../errors/app_error.dart';

/// A single GPS fix, as the server's geofence/anti-replay triggers expect it.
class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.mocked,
  });

  final double lat;
  final double lng;
  final double accuracyM;
  final bool mocked;
}

abstract class LocationService {
  /// Returns the device's current position, requesting permission if needed.
  /// Throws [PermissionDeniedError] when location is off or denied, [UnknownError] when no
  /// fix could be obtained — never returns a made-up coordinate.
  Future<LocationFix> currentFix();
}

class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService();

  @override
  Future<LocationFix> currentFix() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const PermissionDeniedError(
        'Turn on location services to clock in or out.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const PermissionDeniedError(
        'Location permission is required to clock in or out. Enable it in Settings.',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LocationFix(
        lat: position.latitude,
        lng: position.longitude,
        accuracyM: position.accuracy,
        mocked: position.isMocked,
      );
    } catch (_) {
      throw const UnknownError(
        'Could not get your location. Move to an open area and try again.',
      );
    }
  }
}
