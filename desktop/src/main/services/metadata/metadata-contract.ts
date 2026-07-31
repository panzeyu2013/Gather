import type {
  MetadataField,
  MetadataMutationSource,
  MetadataPatch,
} from '@gather/shared'

const LABELS = new Set(['', 'None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple'])

export function normalizeKeywords(values: unknown): string[] {
  if (!Array.isArray(values)) throw new Error('keywords must be an array')
  return [...new Set(values
    .filter((value): value is string => typeof value === 'string')
    .map(value => value.trim())
    .filter(Boolean))]
}

export function validateMetadataPatch(patch: MetadataPatch): MetadataPatch {
  if (!patch || typeof patch !== 'object') throw new Error('metadata patch must be an object')
  const normalized: MetadataPatch = {}
  if (patch.rating) {
    if (patch.rating.op !== 'set' || !Number.isInteger(patch.rating.value) || patch.rating.value < 0 || patch.rating.value > 5) {
      throw new Error('rating must be an integer from 0 to 5')
    }
    normalized.rating = { op: 'set', value: patch.rating.value }
  }
  if (patch.label) {
    if (patch.label.op !== 'set' || typeof patch.label.value !== 'string' || !LABELS.has(patch.label.value)) {
      throw new Error('label must be a Capture One color label')
    }
    normalized.label = { op: 'set', value: patch.label.value }
  }
  if (patch.keywords) {
    if (!['append', 'replace', 'remove'].includes(patch.keywords.op)) {
      throw new Error('keywords operation must be append, replace, or remove')
    }
    normalized.keywords = {
      op: patch.keywords.op,
      values: normalizeKeywords(patch.keywords.values),
    }
  }
  if (Object.keys(normalized).length === 0) throw new Error('metadata patch cannot be empty')
  return normalized
}

export function dirtyFieldsForPatch(patch: MetadataPatch): MetadataField[] {
  return (['rating', 'label', 'keywords'] as MetadataField[])
    .filter(field => patch[field] !== undefined)
}

export function patchToOutboxValues(patch: MetadataPatch): Record<string, unknown> {
  const values: Record<string, unknown> = {}
  if (patch.rating) values.rating = patch.rating.value
  if (patch.label) values.label = patch.label.value
  if (patch.keywords) values.keywords = patch.keywords
  return values
}

export function assertMutationSource(source: string): asserts source is MetadataMutationSource {
  if (!['culling', 'face-keyword', 'similarity', 'template', 'manual'].includes(source)) {
    throw new Error(`Unsupported metadata mutation source: ${source}`)
  }
}
