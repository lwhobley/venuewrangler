import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/chat/application/chat_providers.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

Venue _venue(String id) => Venue(
      id: id,
      organizationId: 'org-1',
      name: 'Venue $id',
      createdAt: DateTime(2026),
    );

void main() {
  test('switching the active venue closes the open chat thread', () {
    final container = ProviderContainer(
      overrides: [currentUserIdProvider.overrideWith((ref) => 'user-1')],
    );
    addTearDown(container.dispose);
    // Keep the autoDispose provider alive, as the chat screen does.
    final sub = container.listen(activeConversationIdProvider, (_, __) {});
    addTearDown(sub.close);

    container.read(activeVenueProvider.notifier).state = _venue('venue-1');
    container.read(activeConversationIdProvider.notifier).state = 'conv-1';
    expect(container.read(activeConversationIdProvider), 'conv-1');

    // Same venue re-selected: the thread stays open.
    container.read(activeVenueProvider.notifier).state = _venue('venue-1');
    expect(container.read(activeConversationIdProvider), 'conv-1');

    container.read(activeVenueProvider.notifier).state = _venue('venue-2');
    expect(container.read(activeConversationIdProvider), isNull);
  });
}
