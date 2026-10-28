import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts', 'tests/**/*.test.tsx', 'src/security/**/*.test.ts', 'src/trust/**/*.test.ts', 'src/integrations/**/*.test.ts', 'src/lib/**/*.test.ts', 'src/routes/**/*.test.ts'],
    exclude: ['tmp_build_source/**', 'dist/**', 'node_modules/**'],
    // Keep the suite deterministic on constrained Railway builders. Several
    // integration files boot independent PGlite instances; allowing Vitest to
    // fan out across every CPU can starve their setup hooks even when the SQL
    // itself is healthy. Preserve file isolation, but bound concurrency.
    maxWorkers: 2,
    minWorkers: 1,
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
