// Electron-aware locale resolution wrapper over the pure resolveEffectiveLocale
// (./locale): callers that live in the main process and need the *current*
// effective locale (settings `ui_language` override > `--lang` switch >
// `app.getLocale()` > 'en') get it here instead of re-assembling the three
// sources at every call site.

import { app } from 'electron'
import { resolveEffectiveLocale, type AppLocale } from './locale'

export function effectiveAppLocale(uiLanguage?: string): AppLocale {
  return resolveEffectiveLocale(
    app.commandLine.getSwitchValue('lang'),
    app.getLocale(),
    uiLanguage,
  )
}
