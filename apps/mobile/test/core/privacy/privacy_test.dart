import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/privacy/privacy_overlay.dart';
import 'package:venuewrangler_mobile/core/privacy/screen_security.dart';

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await tester.pump();
}

void main() {
  const coverKey = ValueKey('privacy-overlay');

  group('PrivacyOverlay', () {
    Widget app({bool enabled = true, Widget? child}) => MaterialApp(
          home: PrivacyOverlay(
            enabled: enabled,
            child: child ?? const Scaffold(body: Text('secret schedule')),
          ),
        );

    testWidgets('covers the app when it leaves the foreground', (tester) async {
      await tester.pumpWidget(app());
      expect(find.byKey(coverKey), findsNothing);

      await _lifecycle(tester, AppLifecycleState.inactive);
      expect(find.byKey(coverKey), findsOneWidget);

      await _lifecycle(tester, AppLifecycleState.paused);
      expect(find.byKey(coverKey), findsOneWidget);

      await _lifecycle(tester, AppLifecycleState.resumed);
      expect(find.byKey(coverKey), findsNothing);
      expect(find.text('secret schedule'), findsOneWidget);
    });

    testWidgets('does nothing when disabled (web and desktop)', (tester) async {
      await tester.pumpWidget(app(enabled: false));

      await _lifecycle(tester, AppLifecycleState.inactive);

      expect(find.byKey(coverKey), findsNothing);
    });

    testWidgets('showing the cover does not rebuild the app underneath',
        (tester) async {
      await tester.pumpWidget(
        app(child: const Scaffold(body: TextField(key: ValueKey('field')))),
      );
      await tester.enterText(find.byKey(const ValueKey('field')), 'draft');

      await _lifecycle(tester, AppLifecycleState.inactive);
      await _lifecycle(tester, AppLifecycleState.resumed);

      // The text survives only if the subtree kept its state (was not re-parented).
      expect(find.text('draft'), findsOneWidget);
    });
  });

  group('ScreenSecurityService', () {
    late List<bool> calls;
    late ScreenSecurityService service;

    setUp(() {
      calls = [];
      const channel = MethodChannel('test/screen_security');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setSecure') {
          calls.add((call.arguments as Map)['secure'] as bool);
        }
        return null;
      });
      service =
          ScreenSecurityService(channel: channel, isSupported: () => true);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    });

    test('is counted: set by the first holder, cleared by the last', () async {
      await service.acquire();
      await service.acquire();
      expect(calls, [true]);

      await service.release();
      expect(calls, [true]);

      await service.release();
      expect(calls, [true, false]);
      expect(service.holders, 0);
    });

    test('an unbalanced release is ignored', () async {
      await service.release();

      expect(calls, isEmpty);
      expect(service.holders, 0);
    });

    test('an unsupported platform never calls the channel', () async {
      final unsupported = ScreenSecurityService(
        channel: const MethodChannel('test/screen_security'),
        isSupported: () => false,
      );

      await unsupported.acquire();
      await unsupported.release();

      expect(calls, isEmpty);
    });

    test('a host without the channel is tolerated', () async {
      final missing = ScreenSecurityService(
        channel: const MethodChannel('test/does_not_exist'),
        isSupported: () => true,
      );

      await missing.acquire();
      await missing.release();
    });
  });

  group('SecureScreen', () {
    late List<bool> calls;
    late ScreenSecurityService service;

    setUp(() {
      calls = [];
      const channel = MethodChannel('test/screen_security_widget');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add((call.arguments as Map)['secure'] as bool);
        return null;
      });
      service =
          ScreenSecurityService(channel: channel, isSupported: () => true);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    });

    Widget host(Widget child) => ProviderScope(
          overrides: [screenSecurityServiceProvider.overrideWithValue(service)],
          child: MaterialApp(home: child),
        );

    testWidgets('protects the window while visible and releases on leave',
        (tester) async {
      await tester.pumpWidget(host(const SecureScreen(child: Text('pay'))));
      await tester.pump();
      expect(calls, [true]);

      await tester.pumpWidget(host(const Text('elsewhere')));
      await tester.pump();
      expect(calls, [true, false]);
    });

    testWidgets('a kept-alive but hidden screen does not hold the flag',
        (tester) async {
      Widget tab({required bool active}) => host(
            TickerMode(
              enabled: active,
              child: const SecureScreen(child: Text('pay')),
            ),
          );

      await tester.pumpWidget(tab(active: true));
      await tester.pump();
      expect(calls, [true]);

      await tester.pumpWidget(tab(active: false));
      await tester.pump();
      await tester.pump();
      expect(calls, [true, false]);

      await tester.pumpWidget(tab(active: true));
      await tester.pump();
      await tester.pump();
      expect(calls, [true, false, true]);
    });
  });
}
