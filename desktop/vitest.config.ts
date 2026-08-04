import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  test: {
    environment: 'jsdom',
    globals: true,
    include: ['tests/unit/**/*.test.ts'],
    root: path.resolve(__dirname, '..'),
  },
  resolve: {
    alias: {
      '@gather/shared': path.resolve(__dirname, '../packages/shared/src'),
      // better-sqlite3 is rebuilt for Electron's ABI by `electron-rebuild`,
      // which the system Node running vitest cannot load. Use a separately
      // installed copy compiled for the system Node instead, so unit tests
      // work without manually rebuilding native modules.
      'better-sqlite3': path.resolve(__dirname, '../node_modules/better-sqlite3-system'),
    },
  },
})
