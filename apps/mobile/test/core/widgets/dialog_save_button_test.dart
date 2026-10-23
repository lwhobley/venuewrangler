import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/widgets/dialog_save_button.dart';

void main() {
  testWidgets('invalid and failed saves retain the form and typed data',
      (tester) async {
    var calls = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Report'),
                  content: TextField(controller: controller),
                  actions: [
                    DialogSaveButton(
                      label: 'Save',
                      validate: () =>
                          controller.text.isEmpty ? 'Title required' : null,
                      save: () async {
                        calls++;
                        throw StateError('offline');
                      },
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Title required'), findsOneWidget);
    expect(calls, 0);
    await tester.enterText(find.byType(TextField), 'Keep my incident details');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(controller.text, 'Keep my incident details');
    expect(find.textContaining('Your details are still here'), findsOneWidget);
  });
}
