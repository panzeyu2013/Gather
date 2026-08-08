import i18n from 'i18next'
import { initReactI18next, useTranslation as useReactI18nextTranslation } from 'react-i18next'
import zhCN from './zh-CN.json'
import en from './en.json'

export const resources = {
  'zh-CN': { translation: zhCN },
  en: { translation: en },
} as const

export type TranslationKey = keyof typeof zhCN

export type TranslationOptions = {
  count?: number
  [key: string]: unknown
}

export type TypedTFunction = {
  (key: TranslationKey): string
  (key: TranslationKey, options: TranslationOptions): string
  (keys: readonly TranslationKey[]): string
  (keys: readonly TranslationKey[], options: TranslationOptions): string
}

export function detectLanguage(): string {
  if (typeof navigator !== 'undefined') {
    return navigator.language.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en'
  }
  return 'en'
}

i18n.use(initReactI18next).init({
  resources,
  // Import-time default so module-level t() in pure helpers works pre-init;
  // main.tsx overrides it with the main-process effective locale before the
  // first render (see initI18n below).
  lng: detectLanguage(),
  fallbackLng: 'en',
  interpolation: {
    escapeValue: false,
  },
})

/**
 * Apply the effective locale (from `window.gather.getAppLocale()`). main.tsx
 * awaits this BEFORE ReactDOM.render so the app never paints in the wrong
 * language; the Settings language row calls it again mid-session to switch
 * UI copy instantly.
 */
export async function initI18n(lng: string): Promise<void> {
  await i18n.changeLanguage(lng)
}

export const t: TypedTFunction = ((key: TranslationKey, options?: TranslationOptions) =>
  i18n.t(key, options)) as TypedTFunction

export function useTranslation() {
  const { t: instanceT, ...rest } = useReactI18nextTranslation()
  return { ...rest, t: instanceT as TypedTFunction }
}

export default i18n
