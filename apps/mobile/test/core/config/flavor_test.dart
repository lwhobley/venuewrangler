import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/config/flavor.dart';

void main() {
  group('AppFlavor.fromString', () {
    test('parses each known flavor name', () {
      expect(AppFlavor.fromString('development'), AppFlavor.development);
      expect(AppFlavor.fromString('staging'), AppFlavor.staging);
      expect(AppFlavor.fromString('production'), AppFlavor.production);
    });

    test('falls back to development for an unknown value', () {
      expect(AppFlavor.fromString('nonsense'), AppFlavor.development);
    });
  });

  group('AppFlavor.isProduction', () {
    test('is true only for production', () {
      expect(AppFlavor.production.isProduction, isTrue);
      expect(AppFlavor.development.isProduction, isFalse);
      expect(AppFlavor.staging.isProduction, isFalse);
    });
  });
}
