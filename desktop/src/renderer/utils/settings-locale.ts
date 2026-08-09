import type { AppLocale } from '../api/settings'

export async function resetSettingsAndApplyLocale(
  resetToDefaults: () => Promise<void>,
  getAppLocale: () => Promise<{ language: AppLocale }>,
  applyLocale: (language: AppLocale) => Promise<void>,
): Promise<AppLocale> {
  await resetToDefaults()
  const { language } = await getAppLocale()
  await applyLocale(language)
  return language
}
