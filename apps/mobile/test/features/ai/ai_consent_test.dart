import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/core/network/supabase_providers.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/application/org_ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_consent_store.dart';
import 'package:venuewrangler_mobile/features/ai/data/org_ai_settings_repository.dart';
import 'package:venuewrangler_mobile/features/ai/presentation/ai_consent_dialog.dart';
import 'package:venuewrangler_mobile/features/ai/presentation/org_ai_toggle_tile.dart';

class _MemoryConsentStore implements AiConsentStore {
  final granted = <String>{};

  @override
  Future<bool> hasConsent(String userId) async => granted.contains(userId);

  @override
  Future<void> grant(String userId) async => granted.add(userId);
}

class _FakeOrgAiSettings implements OrgAiSettingsRepository {
  _FakeOrgAiSettings({this.enabled = false});

  bool enabled;
  Object? setError;
  final sets = <bool>[];

  @override
  Future<bool> fetchEnabled(String organizationId) async => enabled;

  @override
  Future<void> setEnabled(String organizationId, bool value) async {
    if (setError != null) throw setError!;
    sets.add(value);
    enabled = value;
  }
}

void main() {
  group('processor consent gate', () {
    late List<http.Request> requests;
    late http.Response Function(http.Request) respond;
    late _MemoryConsentStore store;
    late int prompts;
    late Future<bool> Function() prompter;

    ProviderContainer container({String? userId = 'user-1'}) {
      final client = SupabaseClient(
        'https://ai.test',
        'public-test-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return respond(request);
        }),
      );
      addTearDown(client.dispose);
      final container = ProviderContainer(
        overrides: [
          supabaseClientProvider.overrideWithValue(client),
          currentUserIdProvider.overrideWithValue(userId),
          aiConsentStoreProvider.overrideWithValue(store),
          aiConsentPrompterProvider.overrideWithValue(() {
            prompts++;
            return prompter();
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    http.Response answer(http.Request r) => http.Response(
          jsonEncode({
            'result': {'answer': 'Open at five', 'needs_more_info': false},
          }),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );

    setUp(() {
      requests = [];
      respond = answer;
      store = _MemoryConsentStore();
      prompts = 0;
      prompter = () async => true;
    });

    test('the first AI call shows the disclosure, later calls do not',
        () async {
      final ai = container().read(aiRepositoryProvider);

      final first = await ai.askWrangler(venueId: 'v1', question: 'Hours?');
      await ai.askWrangler(venueId: 'v1', question: 'Again?');

      expect(first.answer, 'Open at five');
      expect(prompts, 1);
      expect(requests, hasLength(2));
      expect(store.granted, {'user-1'});
    });

    test('declining sends nothing and explains why', () async {
      prompter = () async => false;
      final ai = container().read(aiRepositoryProvider);

      await expectLater(
        ai.askWrangler(venueId: 'v1', question: 'Hours?'),
        throwsA(
          isA<AiUnavailableError>().having(
            (e) => e.message,
            'message',
            contains('need your OK'),
          ),
        ),
      );

      expect(requests, isEmpty);
      expect(store.granted, isEmpty);
    });

    test('an earlier acknowledgement skips the prompt', () async {
      store.granted.add('user-1');
      final ai = container().read(aiRepositoryProvider);

      await ai.parseStaffImport(venueId: 'v1', pastedText: 'Ann, a@b.co');

      expect(prompts, 0);
    });

    test('a different user on the same device is asked again', () async {
      store.granted.add('user-1');
      final ai = container(userId: 'user-2').read(aiRepositoryProvider);

      await ai.askWrangler(venueId: 'v1', question: 'Hours?');

      expect(prompts, 1);
      expect(store.granted, {'user-1', 'user-2'});
    });

    test('simultaneous first calls share one prompt', () async {
      final gate = Completer<bool>();
      prompter = () => gate.future;
      final ai = container().read(aiRepositoryProvider);

      final calls = [
        ai.askWrangler(venueId: 'v1', question: 'One'),
        ai.generateShiftInsights(venueId: 'v1', context: 'Two'),
      ];
      await Future<void>.delayed(Duration.zero);
      gate.complete(true);
      respond = (r) => http.Response(
            jsonEncode({
              'result': {'answer': 'ok', 'insights': <Object>[]},
            }),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          );
      await Future.wait(calls);

      expect(prompts, 1);
    });

    test('other server refusals map to friendly messages', () async {
      store.granted.add('user-1');
      final ai = container().read(aiRepositoryProvider);
      const expected = {
        'subscription_required': 402,
        'monthly_user_budget_exceeded': 402,
        'ai_unavailable': 503,
        'rate_limited': 429,
      };
      for (final entry in expected.entries) {
        respond = (r) => http.Response(
              jsonEncode({'error': entry.key}),
              entry.value,
              request: r,
              headers: {'content-type': 'application/json'},
            );
        await expectLater(
          ai.askWrangler(venueId: 'v1', question: 'Hours?'),
          throwsA(
            isA<AiUnavailableError>().having(
              (e) => e.message,
              entry.key,
              isNot(contains('_')),
            ),
          ),
          reason: entry.key,
        );
      }
    });

    test('ai_disabled_for_org is explained, pointing at Settings', () async {
      store.granted.add('user-1');
      respond = (r) => http.Response(
            jsonEncode({'error': 'ai_disabled_for_org'}),
            403,
            request: r,
            headers: {'content-type': 'application/json'},
          );
      final ai = container().read(aiRepositoryProvider);

      await expectLater(
        ai.askWrangler(venueId: 'v1', question: 'Hours?'),
        throwsA(
          isA<AiUnavailableError>().having(
            (e) => e.message,
            'message',
            allOf(contains('turned off'), contains('Settings')),
          ),
        ),
      );
    });
  });

  group('SecureAiConsentStore', () {
    test('remembers the acknowledgement per user', () async {
      FlutterSecureStorage.setMockInitialValues({});
      const store = SecureAiConsentStore();

      expect(await store.hasConsent('u1'), isFalse);
      await store.grant('u1');

      expect(await store.hasConsent('u1'), isTrue);
      expect(await store.hasConsent('u2'), isFalse);
    });

    test('an older disclosure version does not count', () async {
      FlutterSecureStorage.setMockInitialValues({
        'ai_processor_consent.u1': 'v0',
      });

      expect(await const SecureAiConsentStore().hasConsent('u1'), isFalse);
    });
  });

  testWidgets('the disclosure names Groq, what is sent, and the privacy policy',
      (tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await showAiConsentDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Groq'), findsOneWidget);
    expect(find.text('What is sent'), findsOneWidget);
    expect(find.text('Read the privacy policy'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand, continue'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  group('OrgAiToggleTile', () {
    Future<_FakeOrgAiSettings> pump(
      WidgetTester tester, {
      bool enabled = false,
    }) async {
      final settings = _FakeOrgAiSettings(enabled: enabled);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            orgAiSettingsRepositoryProvider.overrideWithValue(settings),
          ],
          child: const MaterialApp(
            home: Scaffold(body: OrgAiToggleTile(organizationId: 'org-1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return settings;
    }

    testWidgets('reflects the organization setting and turns it on',
        (tester) async {
      final settings = await pump(tester);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(settings.sets, [true]);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
    });

    testWidgets('a forbidden change is explained and the switch stays put',
        (tester) async {
      final settings = await pump(tester, enabled: true);
      settings.setError = const PostgrestException(
        message: 'forbidden',
        code: '42501',
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(
        find.text('Only owners and admins can change this.'),
        findsOneWidget,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
    });
  });
}
