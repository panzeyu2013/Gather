// Locale resolution for the app UI and menu (docs/DESIGN_IMPROVEMENTS.md 4.2):
// the effective locale is 设置覆盖 (persisted `ui_language` setting) >
// `--lang` Chromium/Electron switch > `app.getLocale()`; anything not
// zh-prefixed falls back to 'en'. Pure module (no electron import) so the
// chain is unit-testable; the `app.getLocale()` / switch values are supplied
// by the caller (main/index.ts, settings.ipc.ts).

export type AppLocale = 'zh-CN' | 'en'

export function isAppLocale(value: unknown): value is AppLocale {
  return value === 'zh-CN' || value === 'en'
}

export function resolveAppLocale(langSwitch: string, systemLocale: string): AppLocale {
  const raw = (langSwitch || systemLocale).toLowerCase()
  return raw.startsWith('zh') ? 'zh-CN' : 'en'
}

/** Settings override > `--lang` switch > system locale > 'en' fallback. */
export function resolveEffectiveLocale(
  langSwitch: string,
  systemLocale: string,
  uiLanguage?: string,
): AppLocale {
  if (isAppLocale(uiLanguage)) return uiLanguage
  return resolveAppLocale(langSwitch, systemLocale)
}
