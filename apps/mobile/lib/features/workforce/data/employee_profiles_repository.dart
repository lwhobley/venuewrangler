import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/employee_hr_profile.dart';

abstract interface class EmployeeProfilesRepository {
  Future<EmployeeHrProfile> fetchHr(StaffProfileKey key);
  Future<void> saveHr(StaffProfileKey key, Map<String, dynamic> fields);
  Future<StaffPhoto?> fetchPhoto(StaffProfileKey key);
  Future<void> uploadPhoto(
    StaffProfileKey key,
    String organizationId,
    String filePath,
  );
}

String profileImageMime(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
    throw const FormatException('Choose a photo smaller than 5 MB.');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      [137, 80, 78, 71, 13, 10, 26, 10]
          .asMap()
          .entries
          .every((e) => bytes[e.key] == e.value)) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return 'image/webp';
  }
  throw const FormatException('Choose a JPEG, PNG, or WebP photo.');
}

class SupabaseEmployeeProfilesRepository implements EmployeeProfilesRepository {
  const SupabaseEmployeeProfilesRepository(this.client);
  final SupabaseClient client;

  @override
  Future<EmployeeHrProfile> fetchHr(StaffProfileKey key) async {
    final row = await client
        .from('employee_hr_profiles')
        .select()
        .eq('venue_id', key.venueId)
        .eq('user_id', key.userId)
        .maybeSingle();
    return EmployeeHrProfile(row ?? {});
  }

  @override
  Future<void> saveHr(StaffProfileKey key, Map<String, dynamic> fields) async {
    // Only known HR columns reach the DB; RLS and the employment guard are authoritative.
    final allowed = {...personalHrFields.keys, ...employmentHrFields.keys};
    await client.from('employee_hr_profiles').upsert(
      {
        for (final e in fields.entries)
          if (allowed.contains(e.key)) e.key: e.value,
        'venue_id': key.venueId,
        'user_id': key.userId,
      },
      onConflict: 'venue_id,user_id',
    );
  }

  @override
  Future<StaffPhoto?> fetchPhoto(StaffProfileKey key) async {
    final row = await client
        .from('staff_photos')
        .select('storage_path, updated_at')
        .eq('venue_id', key.venueId)
        .eq('user_id', key.userId)
        .maybeSingle();
    if (row == null) return null;
    final url = await client.storage
        .from('profile-photos')
        .createSignedUrl(row['storage_path'] as String, 3600);
    final revision = row['updated_at'] as String;
    return StaffPhoto(
      url: '$url&v=${Uri.encodeComponent(revision)}',
      revision: revision,
    );
  }

  @override
  Future<void> uploadPhoto(
    StaffProfileKey key,
    String organizationId,
    String filePath,
  ) async {
    final bytes = await XFile(filePath).readAsBytes();
    final mime = profileImageMime(bytes);
    final path = '$organizationId/${key.venueId}/${key.userId}.photo';
    await client.storage.from('profile-photos').uploadBinary(
          path,
          bytes,
          fileOptions:
              FileOptions(upsert: true, contentType: mime, cacheControl: '0'),
        );
    await client.from('staff_photos').upsert(
      {'venue_id': key.venueId, 'user_id': key.userId, 'storage_path': path},
      onConflict: 'venue_id,user_id',
    );
  }
}
