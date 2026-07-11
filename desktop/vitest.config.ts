import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  test: {
    environment: 'jsdom',
    globals: true,
    include: ['tests/**/*.test.ts'],
    root: path.resolve(__dirname, '..'),
  },
  resolve: {
    alias: {
      '@gather/shared': path.resolve(__dirname, '../../packages/shared/src'),
    },
  },
})
