import { configDefaults, defineConfig } from 'vitest/config';

export default defineConfig({
  envDir: false,
  test: {
    include: ['**/*.integration.spec.ts'],
    exclude: [...configDefaults.exclude, '.claude/**'],
    fileParallelism: false,
    testTimeout: 30_000,
    // Docker Desktop can take 20-60s to publish a fresh Postgres container,
    // and applying the full production migration history can exceed a minute
    // under cold or resource-constrained CI/desktop starts. Keep bounded
    // headroom so suites reach assertions instead of being reported skipped.
    hookTimeout: 180_000,
  },
});
