import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/integrations/application/integrations_providers.dart';
import 'package:venuewrangler_mobile/features/integrations/data/integrations_repository.dart';
import 'package:venuewrangler_mobile/features/integrations/domain/payroll_connection.dart';
import 'package:venuewrangler_mobile/features/integrations/presentation/integration_complete_screen.dart';

class _FakeIntegrationsRepository implements IntegrationsRepository {
  _FakeIntegrationsRepository({this.failWith});

  final AppError? failWith;
  final completed = <(PayrollProvider, String)>[];

  @override
  Future<void> completeConnection(
    PayrollProvider provider,
    String nonce,
  ) async {
    final error = failWith;
    if (error != null) throw error;
    completed.add((provider, nonce));
  }

  @override
  Future<List<PayrollConnection>> fetchConnectionsForVenue(
    String venueId,
  ) async =>
      const [];

  @override
  Future<String> createConnectUrl(PayrollProvider provider, String venueId) =>
      throw UnimplementedError();

  @override
  Future<void> disconnect(PayrollProvider provider, String venueId) =>
      throw UnimplementedError();
}

Widget _app(
  IntegrationsRepository repository, {
  String? provider,
  String? nonce,
}) {
  final router = GoRouter(
    initialLocation: '/connected',
    routes: [
      GoRoute(
        path: '/connected',
        builder: (_, __) =>
            IntegrationCompleteScreen(provider: provider, nonce: nonce),
      ),
      GoRoute(
        path: '/integrations',
        builder: (_, __) => const Scaffold(body: Text('integrations list')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [integrationsRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  test('PayrollProvider.tryParse accepts only known providers', () {
    expect(PayrollProvider.tryParse('square'), PayrollProvider.square);
    expect(PayrollProvider.tryParse('gusto'), PayrollProvider.gusto);
    expect(PayrollProvider.tryParse('paypal'), isNull);
    expect(PayrollProvider.tryParse(null), isNull);
  });

  testWidgets('redeems the one-time nonce and returns to Integrations',
      (tester) async {
    final repository = _FakeIntegrationsRepository();
    await tester
        .pumpWidget(_app(repository, provider: 'square', nonce: 'abc-123'));
    await tester.pumpAndSettle();

    expect(repository.completed, [(PayrollProvider.square, 'abc-123')]);
    expect(find.text('integrations list'), findsOneWidget);
  });

  testWidgets('shows a friendly error when the server refuses the nonce',
      (tester) async {
    final repository = _FakeIntegrationsRepository(
      failWith: const NotFoundError('This connection link has expired.'),
    );
    await tester
        .pumpWidget(_app(repository, provider: 'gusto', nonce: 'stale'));
    await tester.pumpAndSettle();

    expect(find.text('This connection link has expired.'), findsOneWidget);
    expect(find.text('Back to Integrations'), findsOneWidget);
  });

  testWidgets('a link without provider or nonce never calls the server',
      (tester) async {
    final repository = _FakeIntegrationsRepository();
    await tester.pumpWidget(_app(repository, provider: 'square'));
    await tester.pumpAndSettle();

    expect(repository.completed, isEmpty);
    expect(find.text('This connection link is incomplete.'), findsOneWidget);
  });
}
