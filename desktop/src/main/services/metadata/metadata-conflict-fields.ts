import type { MetadataField } from '@gather/shared'
import type { MetadataWriteAttributes } from './metadata-writer.interface'

export interface FieldConflict {
  field: MetadataField
  baseline: unknown
  local: unknown
  remote: unknown
}

/**
 * Parses and validates the persisted dirty-fields list. A corrupt value yields
 * an empty list (callers decide whether that is fatal).
 */
export function parseDirtyFields(raw: string): MetadataField[] {
  const parsed = tryParseDirtyFields(raw)
  return parsed ?? []
}

/**
 * Strict variant: returns null when the stored JSON is corrupt so callers can
 * fail loudly instead of treating it as a legitimate empty list.
 */
export function tryParseDirtyFields(raw: string): MetadataField[] | null {
  try {
    const parsed = JSON.parse(raw) as unknown
    if (Array.isArray(parsed)) {
      return parsed.filter(
        (field): field is MetadataField =>
          field === 'rating' || field === 'label' || field === 'keywords',
      )
    }
    return null
  } catch {
    return null
  }
}

function currentValue(field: MetadataField, current: MetadataWriteAttributes): unknown {
  if (field === 'keywords') return current.keywords ?? []
  if (field === 'label') return current.label ?? ''
  return current.rating
}

function baselineValue(field: MetadataField, base: Record<string, unknown>): unknown {
  if (field === 'keywords') return base.keywords ?? []
  if (field === 'label') return base.label ?? ''
  return base.rating
}

function localValue(field: MetadataField, local: Record<string, unknown>): unknown {
  if (field === 'keywords') return local.keywords ?? []
  return local[field]
}

/**
 * Produces the per-field list of external changes that collide with the pending
 * write. Drives the conflict-resolution UI.
 */
export function fieldConflicts(
  base: Record<string, unknown>,
  local: Record<string, unknown>,
  current: MetadataWriteAttributes,
  dirtyFields: MetadataField[],
): FieldConflict[] {
  return dirtyFields.flatMap(field => {
    const baseline = baselineValue(field, base)
    const remote = currentValue(field, current)
    if (JSON.stringify(baseline) === JSON.stringify(remote)) return []
    return [{
      field,
      baseline,
      local: localValue(field, local),
      remote,
    }]
  })
}

/**
 * Fast boolean gate used before writing: true when any dirty field changed on
 * disk since the baseline was captured. Note: this intentionally uses stricter
 * normalization than `fieldConflicts` (empty string == missing label), so a
 * missing baseline label does not surface as a spurious conflict.
 */
export function hasFieldConflict(
  base: Record<string, unknown>,
  current: MetadataWriteAttributes,
  dirtyFields: MetadataField[],
): boolean {
  return dirtyFields.some(field => {
    if (field === 'rating') return current.rating !== base.rating
    if (field === 'label') return (current.label ?? '') !== (base.label ?? '')
    if (field === 'keywords') {
      return JSON.stringify(current.keywords ?? []) !== JSON.stringify(base.keywords ?? [])
    }
    return true
  })
}
