import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_access.dart';
import 'package:venuewrangler_mobile/features/ai/presentation/wrangler_assistant_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

void main() {
  test('only managers, admins and owners may use the assistant', () {
    for (final role in [
      'venue_manager',
      'organization_admin',
      'organization_owner',
    ]) {
      expect(canUseWranglerAssistant(role), isTrue, reason: role);
    }
    for (final role in ['supervisor', 'staff', null, 'platform_admin', '']) {
      expect(canUseWranglerAssistant(role), isFalse, reason: '$role');
    }
  });

  test('both manager-only refusal codes map to a permission message', () {
    for (final code in ['manager_permission_required', 'not_a_venue_manager']) {
      final error = mapAiFunctionException(
        FunctionException(status: 403, details: {'error': code}),
      );
      expect(error, isA<PermissionDeniedError>(), reason: code);
      expect(error.message, contains('managers'), reason: code);
    }
  });

  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime(2026),
  );

  Future<void> pumpFor(WidgetTester tester, String role) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          myVenueRoleProvider.overrideWith((ref) async => role),
        ],
        child: const MaterialApp(home: WranglerAssistantScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('supervisors see a managers-only state instead of the form',
      (tester) async {
    await pumpFor(tester, 'supervisor');
    expect(find.text(wranglerManagersOnlyMessage), findsOneWidget);
    expect(find.text('Ask'), findsNothing);
  });

  testWidgets('managers get the question form', (tester) async {
    await pumpFor(tester, 'venue_manager');
    expect(find.text(wranglerManagersOnlyMessage), findsNothing);
    expect(find.text('Ask'), findsOneWidget);
  });
}
