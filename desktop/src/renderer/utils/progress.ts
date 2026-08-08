import { t as defaultT, type TranslationKey, type TypedTFunction } from '../locales'

/**
 * Translate a main-process progress phase code (design_improvements.md
 * 4.4.2): event payloads carry `phase: 'index.scanning'` and the renderer
 * maps it to copy via `progress.<phase>` keys. Unknown phases fall back to
 * the generic scanning copy.
 */
export function translatePhase(
  phase: string | undefined,
  translator: TypedTFunction = defaultT,
): string {
  if (!phase) return translator('progress.unspecific')
  return translator([`progress.${phase}` as TranslationKey, 'progress.unspecific'])
}
