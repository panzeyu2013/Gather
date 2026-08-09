import { isGatherErrorCode } from '@gather/shared'
import { t as defaultT, type TranslationKey, type TypedTFunction } from '../locales'

/**
 * Map a main-process GatherErrorCode to translated copy
 * (design_improvements.md 4.4.2 / 4.5): multi-key fallback
 * `t(['error.<code>', 'error.unspecific'])` so unknown codes degrade to the
 * generic message instead of leaking raw codes. Interpolation params (e.g.
 * {{expected}}/{{current}} for CULLING_REVISION_CONFLICT) ride on the thrown
 * Error (see translateError) and are forwarded into the t() options.
 */
export function translateErrorCode(
  code: string,
  translator: TypedTFunction = defaultT,
  params?: Record<string, unknown>,
): string {
  if (isGatherErrorCode(code)) {
    return params !== undefined
      ? translator([`error.${code}` as TranslationKey, 'error.unspecific'], params)
      : translator([`error.${code}` as TranslationKey, 'error.unspecific'])
  }
  return code
}

/** Translate any Error instance — or plain code string — that carries a GatherErrorCode. */
export function translateError(
  error: unknown,
  translator: TypedTFunction = defaultT,
): string {
  const params = typeof error === 'object' && error !== null
    ? (error as { params?: Record<string, unknown> }).params
    : undefined
  if (typeof error === 'string') {
    return isGatherErrorCode(error) ? translateErrorCode(error, translator, params) : error
  }
  if (error instanceof Error && isGatherErrorCode(error.message)) {
    return translateErrorCode(error.message, translator, params)
  }
  return error instanceof Error ? error.message : String(error)
}

/**
 * Map a persisted job failure (error_message column) for display: a
 * GatherErrorCode is translated like any other code; anything else
 * (operational diagnostics like 'worker_error', raw English invariants) must
 * never be shown verbatim, so it degrades to the generic failure copy. The
 * raw detail stays available for tooltips.
 */
export function translateJobErrorMessage(
  message: string | null | undefined,
  translator: TypedTFunction = defaultT,
): string {
  if (!message) return translator('error.unspecific')
  if (isGatherErrorCode(message)) return translateErrorCode(message, translator)
  return translator('error.unspecific')
}
