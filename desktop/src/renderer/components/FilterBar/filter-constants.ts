import type { FilterRule } from '@gather/shared'
import type { TranslationKey } from '../../locales'

export const FILTER_FIELDS: { value: string; labelKey: TranslationKey }[] = [
  { value: 'filename', labelKey: 'filter.field.filename' },
  { value: 'checksum', labelKey: 'filter.field.checksum' },
  { value: 'date_taken', labelKey: 'filter.field.dateTaken' },
  { value: 'camera_make', labelKey: 'filter.field.cameraMake' },
  { value: 'camera_model', labelKey: 'filter.field.cameraModel' },
  { value: 'lens_model', labelKey: 'filter.field.lensModel' },
  { value: 'focal_length', labelKey: 'filter.field.focalLength' },
  { value: 'f_number', labelKey: 'filter.field.fNumber' },
  { value: 'iso', labelKey: 'filter.field.iso' },
  { value: 'rating', labelKey: 'filter.field.rating' },
  { value: 'has_face', labelKey: 'filter.field.hasFace' },
  { value: 'person', labelKey: 'filter.field.person' },
  { value: 'keywords', labelKey: 'filter.field.keywords' },
]

export const FILTER_OPERATORS: { value: FilterRule['operator']; labelKey: TranslationKey }[] = [
  { value: 'eq', labelKey: 'filter.op.eq' },
  { value: 'neq', labelKey: 'filter.op.neq' },
  { value: 'contains', labelKey: 'filter.op.contains' },
  { value: 'starts_with', labelKey: 'filter.op.startsWith' },
  { value: 'gte', labelKey: 'filter.op.gte' },
  { value: 'lte', labelKey: 'filter.op.lte' },
  { value: 'gt', labelKey: 'filter.op.gt' },
  { value: 'lt', labelKey: 'filter.op.lt' },
  { value: 'in', labelKey: 'filter.op.in' },
  { value: 'contains_any', labelKey: 'filter.op.containsAny' },
  { value: 'contains_all', labelKey: 'filter.op.containsAll' },
  { value: 'between', labelKey: 'filter.op.between' },
  { value: 'exists', labelKey: 'filter.op.exists' },
]

export const OPERATORS_BY_FIELD: Record<string, FilterRule['operator'][]> = {
  has_face: ['eq', 'exists'],
  person: ['eq', 'contains', 'in', 'contains_any'],
  keywords: ['contains_any', 'contains_all', 'exists'],
}

export function getFilterOperators(field: string): { value: FilterRule['operator']; labelKey: TranslationKey }[] {
  if (OPERATORS_BY_FIELD[field]) {
    return FILTER_OPERATORS.filter((op) => OPERATORS_BY_FIELD[field].includes(op.value))
  }
  return FILTER_OPERATORS
}

export function parseFilterValue(field: string, operator: FilterRule['operator'], raw: string): unknown {
  if (field === 'has_face') {
    return raw === 'true' || raw === '1'
  }
  if (operator === 'in' || operator === 'between') {
    return raw.split(',').map((s) => s.trim())
  }
  if (operator === 'contains_any' || operator === 'contains_all' || field === 'keywords') {
    return raw.split(',').map((s) => s.trim())
  }
  const numFields = new Set(['focal_length', 'f_number', 'iso', 'rating', 'gps_latitude', 'gps_longitude', 'width', 'height', 'file_size'])
  if (numFields.has(field)) {
    const n = Number(raw)
    return isNaN(n) ? raw : n
  }
  return raw
}
