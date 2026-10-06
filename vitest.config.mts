import { defineConfig, configDefaults } from 'vitest/config';

export default defineConfig({
  // Tests use explicit fixtures and must never ingest the production-backed
  // local environment snapshot.
  envDir: false,
  test: {
    exclude: [...configDefaults.exclude, '.claude/**', 'dist-site/**', '**/*.integration.spec.ts'],
  },
});
