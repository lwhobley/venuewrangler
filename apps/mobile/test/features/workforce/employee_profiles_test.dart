import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/application/employee_profiles_providers.dart';
import 'package:venuewrangler_mobile/features/workforce/data/employee_profiles_repository.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/employee_hr_profile.dart';
import 'package:venuewrangler_mobile/features/workforce/presentation/employee_profile_widgets.dart';

class _Profiles implements EmployeeProfilesRepository {
  Map<String, dynamic>? saved;
  StaffProfileKey? savedKey;
  @override
  Future<EmployeeHrProfile> fetchHr(StaffProfileKey key) async =>
      EmployeeHrProfile({'phone': '555-0100', 'hourly_rate_cents': 2500});
  @override
  Future<void> saveHr(StaffProfileKey key, Map<String, dynamic> fields) async {
    saved = fields;
    savedKey = key;
  }

  @override
  Future<StaffPhoto?> fetchPhoto(StaffProfileKey key) async => null;
  @override
  Future<void> uploadPhoto(
    StaffProfileKey key,
    String organizationId,
    String filePath,
  ) async {}
}

const _key = (venueId: 'venue-1', userId: 'user-1');
Venue _venue(String id) => Venue(
      id: id,
      organizationId: 'org-1',
      name: 'Venue',
      createdAt: DateTime(2026),
    );

void main() {
  test(
      'clears blank contact fields and excludes protected employment fields from self edits',
      () {
    final payload = hrUpdatePayload(
      {
        'phone': ' ',
        'address': '',
        'hourly_rate_cents': '9999',
        'pto_hours': '500',
      },
      manageEmployment: false,
    );
    expect(payload, {'phone': null, 'address': null});
  });
  test(
      'manager payroll values use cents, permit clears, and normalize certifications',
      () {
    expect(
        hrUpdatePayload(
          {
            'hourly_rate_cents': '24.75',
            'certifications': 'Food safety, Food safety, First aid',
            'pto_hours': '8.5',
          },
          manageEmployment: true,
        ),
        {
          'hourly_rate_cents': 2475,
          'certifications': ['Food safety', 'First aid'],
          'pto_hours': 8.5,
        });
    expect(
      hrUpdatePayload(
        {'hourly_rate_cents': ''},
        manageEmployment: true,
      )['hourly_rate_cents'],
      isNull,
    );
    expect(
      () => hrUpdatePayload({'pto_hours': 'NaN'}, manageEmployment: true),
      throwsFormatException,
    );
    expect(hrFieldProblem('date_of_birth', '2026-02-31'), isNotNull);
  });
  test('manager cannot edit peer manager employment details', () {
    expect(canManageEmployeeDetails('venue_manager', 'venue_manager'), isFalse);
    expect(canManageEmployeeDetails('venue_manager', 'staff'), isTrue);
    expect(
      canManageEmployeeDetails('organization_owner', 'venue_manager'),
      isTrue,
    );
    expect(canManageEmployeeDetails('staff', 'staff'), isFalse);
  });
  test('photo bytes reject unsupported types and files above 5 MB', () {
    expect(
      profileImageMime(Uint8List.fromList([255, 216, 255, 0])),
      'image/jpeg',
    );
    expect(
      () => profileImageMime(Uint8List.fromList('a file.jpg'.codeUnits)),
      throwsFormatException,
    );
    expect(
      () => profileImageMime(Uint8List(5 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
  });
  testWidgets(
      'personal editor saves an explicit field clear without changing payroll',
      (tester) async {
    final repo = _Profiles();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('user-1'),
          activeVenueProvider.overrideWith((ref) => _venue('venue-1')),
          employeeProfilesRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: EmployeeHrCard(
                profileKey: _key,
                name: 'Alex',
                manageEmployment: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit my details'));
    await tester.pumpAndSettle();
    final phone = find.widgetWithText(TextFormField, 'Phone');
    await tester.ensureVisible(phone);
    await tester.enterText(phone, '');
    await tester.tap(find.text('Save details'));
    await tester.pumpAndSettle();
    expect(repo.savedKey, _key);
    expect(repo.saved!['phone'], isNull);
    expect(repo.saved!.containsKey('hourly_rate_cents'), isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('an open editor refuses a save after venue switching',
      (tester) async {
    final repo = _Profiles();
    final container = ProviderContainer(
      overrides: [
        currentUserIdProvider.overrideWithValue('user-1'),
        activeVenueProvider.overrideWith((ref) => _venue('venue-1')),
        employeeProfilesRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: EmployeeHrCard(
                profileKey: _key,
                name: 'Alex',
                manageEmployment: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit my details'));
    await tester.pumpAndSettle();
    container.read(activeVenueProvider.notifier).state = _venue('venue-2');
    await tester.tap(find.text('Save details'));
    await tester.pumpAndSettle();
    expect(repo.saved, isNull);
    expect(tester.takeException(), isNull);
  });
}
