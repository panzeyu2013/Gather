import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  test: {
    environment: 'jsdom',
    globals: true,
  },
  resolve: {
    alias: {
      '@gather/shared': path.resolve(__dirname, '../../packages/shared/src'),
    },
  },
})
