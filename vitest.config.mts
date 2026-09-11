import { defineConfig, configDefaults } from 'vitest/config';

export default defineConfig({
  // Tests use explicit fixtures and must never ingest the production-backed
  // local environment snapshot.
  envDir: false,
  test: {
    exclude: [...configDefaults.exclude, '.claude/**', 'dist-site/**', 'tests/ui/**', '**/*.integration.spec.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text-summary'],
      reportsDirectory: 'coverage/core',
      // Include untested source files so coverage cannot be made to look high
      // by simply omitting difficult modules from the report.
      all: true,
      include: ['packages/api/src/**/*.ts', 'lib/**/*.ts'],
      exclude: ['**/*.spec.ts', '**/*.integration.spec.ts', '**/test/**', '**/*.d.ts'],
      thresholds: {
        statements: 45,
        branches: 35,
        functions: 40,
        lines: 45,
      },
    } as any,
  },
});
