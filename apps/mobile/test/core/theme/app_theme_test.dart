import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/core/theme/ops_colors.dart';
import 'package:venuewrangler_mobile/core/widgets/status_chip.dart';

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

void main() {
  const minRatio = 4.5;

  for (final entry
      in {'light': AppTheme.light(), 'dark': AppTheme.dark()}.entries) {
    group('${entry.key} theme contrast (WCAG AA 4.5:1)', () {
      final theme = entry.value;
      final s = theme.colorScheme;
      final ops = theme.extension<OpsColors>()!;

      test('body and muted text on the workspace and card surfaces', () {
        for (final bg in [
          s.surface,
          s.surfaceContainerLow,
          s.surfaceContainerHigh,
        ]) {
          expect(_contrast(s.onSurface, bg), greaterThanOrEqualTo(minRatio));
          expect(
            _contrast(s.onSurfaceVariant, bg),
            greaterThanOrEqualTo(minRatio),
          );
        }
      });

      test('text on filled primary and secondary controls', () {
        expect(
          _contrast(s.onPrimary, s.primary),
          greaterThanOrEqualTo(minRatio),
        );
        expect(
          _contrast(s.onSecondary, s.secondary),
          greaterThanOrEqualTo(minRatio),
        );
        expect(_contrast(s.onError, s.error), greaterThanOrEqualTo(minRatio));
      });

      test('coral text-button colour on the workspace surface', () {
        expect(
          _contrast(ops.primaryStrong, s.surface),
          greaterThanOrEqualTo(minRatio),
        );
      });

      test('every status tone reads on its own tinted chip, on both surfaces',
          () {
        for (final tone in Tone.values) {
          final c = ops.of(tone);
          for (final surface in [s.surface, s.surfaceContainerLow]) {
            final chipBg = _over(c.bg, surface);
            expect(
              _contrast(c.fg, chipBg),
              greaterThanOrEqualTo(minRatio),
              reason: '$tone on ${entry.key}',
            );
          }
        }
      });
    });
  }

  testWidgets('StatusChip shows text and an icon, never colour alone',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: StatusChip(label: 'Ready', tone: Tone.success),
        ),
      ),
    );
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });
}
