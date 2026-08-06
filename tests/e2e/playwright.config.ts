import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  timeout: 30_000,
  // The e2e specs share module-level state (one Electron app per file) and are
  // therefore order-dependent; keep them strictly serial.
  workers: 1,
  fullyParallel: false,
  reporter: 'line',
  // Keep failed-run artifacts inside tests/e2e instead of the repo root.
  outputDir: './test-results',
})
