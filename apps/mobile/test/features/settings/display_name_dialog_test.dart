import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/settings/presentation/display_name_dialog.dart';

void main() {
  Future<List<bool>> open(
    WidgetTester tester,
    Future<void> Function(String) save,
  ) async {
    final results = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await DisplayNameDialog.show(
                context,
                initialName: 'Old',
                save: save,
              ),
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('a blank name keeps the dialog open with a message',
      (tester) async {
    final saved = <String>[];
    final results = await open(tester, (name) async => saved.add(name));

    await tester.enterText(find.byType(TextFormField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Enter a name your team will recognise'), findsOneWidget);
    expect(saved, isEmpty);
    expect(results, isEmpty);
  });

  testWidgets('a failed save stays open, keeps the text and shows the error',
      (tester) async {
    final results = await open(tester, (_) async => throw Exception('offline'));

    await tester.enterText(find.byType(TextFormField), 'Camila Reyes');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Display name'), findsOneWidget);
    expect(find.textContaining('Could not save your name'), findsOneWidget);
    expect(find.text('Camila Reyes'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('a successful save closes and saves the trimmed name',
      (tester) async {
    final saved = <String>[];
    final results = await open(tester, (name) async => saved.add(name));

    await tester.enterText(find.byType(TextFormField), '  Camila  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, ['Camila']);
    expect(results, [true]);
    expect(find.text('Display name'), findsNothing);
  });
}
