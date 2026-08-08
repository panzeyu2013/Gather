import React from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { I18nextProvider } from 'react-i18next'
import App from './App'
import i18n, { t, detectLanguage, initI18n } from './locales'
import './styles/global.css'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 1,
    },
  },
})

// Async bootstrap (i18n P2 收尾): resolve the effective locale from the main
// process (settings override > --lang > system language) and apply it BEFORE
// the first render — the app must not paint with the import-time navigator
// default, or users with a stored preference would see a locale flash.
async function bootstrap(): Promise<void> {
  let locale = detectLanguage()
  try {
    const { language } = await window.gather.getAppLocale()
    locale = language
  } catch (err) {
    // Main-process IPC unavailable (dev/test harness): fall back to the
    // navigator-language detection; only the menu/UI copy may disagree.
    console.warn('Failed to resolve app locale from main process, using navigator language:', err)
  }
  await initI18n(locale)

  document.title = t('app.title')

  createRoot(document.getElementById('root')!).render(
    <React.StrictMode>
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </I18nextProvider>
    </React.StrictMode>,
  )
}

void bootstrap()
