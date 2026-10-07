import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/crm_beo_detail_screen.dart';

void main() {
  test('parseChargeCents accepts dollars and up to two decimals only', () {
    expect(parseChargeCents('12'), 1200);
    expect(parseChargeCents('12.5'), 1250);
    expect(parseChargeCents(' 12.50 '), 1250);
    expect(parseChargeCents('0'), isNull);
    expect(parseChargeCents('1.234'), isNull);
    expect(parseChargeCents('-3'), isNull);
    expect(parseChargeCents('abc'), isNull);
  });

  testWidgets('returns the entered charge and survives the close animation',
      (tester) async {
    BeoChargeDraft? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await AddBeoChargeDialog.show(
              context,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Description'),
      'Linen rental',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '45.5',
    );
    await tester.tap(find.text('Add'));
    // Frames during the exit animation rebuild the fields; with disposed controllers this threw.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result?.description, 'Linen rental');
    expect(result?.cents, 4550);
  });

  testWidgets('rejects an empty form and a bad amount', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => AddBeoChargeDialog.show(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a description'), findsOneWidget);
    expect(
      find.text('Enter a positive amount, up to 2 decimals'),
      findsOneWidget,
    );
  });
}
