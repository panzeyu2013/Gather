import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [
    react(),
    {
      name: 'remove-crossorigin',
      enforce: 'post',
      transformIndexHtml(html) {
        return html.replace(/\s+crossorigin/g, '')
      },
    },
  ],
  root: 'src/renderer',
  base: './',
  build: {
    outDir: '../../dist/renderer',
    emptyOutDir: true,
    modulePreload: false,
  },
  resolve: {
    alias: {
      '@gather/shared': path.resolve(__dirname, '../../packages/shared/src'),
    },
  },
})
