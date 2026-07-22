import type { FilterRule } from '@gather/shared'

export const FILTER_FIELDS: { value: string; label: string }[] = [
  { value: 'filename', label: 'Filename' },
  { value: 'checksum', label: 'Checksum' },
  { value: 'date_taken', label: 'Date Taken' },
  { value: 'camera_make', label: 'Camera Make' },
  { value: 'camera_model', label: 'Camera Model' },
  { value: 'lens_model', label: 'Lens' },
  { value: 'focal_length', label: 'Focal Length' },
  { value: 'f_number', label: 'Aperture' },
  { value: 'iso', label: 'ISO' },
  { value: 'rating', label: 'Rating' },
  { value: 'has_face', label: 'Has Face' },
  { value: 'person', label: 'Person' },
  { value: 'keywords', label: 'Keywords' },
]

export const FILTER_OPERATORS: { value: FilterRule['operator']; label: string }[] = [
  { value: 'eq', label: 'equals' },
  { value: 'neq', label: 'not equals' },
  { value: 'contains', label: 'contains' },
  { value: 'starts_with', label: 'starts with' },
  { value: 'gte', label: '>=' },
  { value: 'lte', label: '<=' },
  { value: 'gt', label: '>' },
  { value: 'lt', label: '<' },
  { value: 'in', label: 'in' },
  { value: 'contains_any', label: 'contains any' },
  { value: 'contains_all', label: 'contains all' },
  { value: 'between', label: 'between' },
  { value: 'regex', label: 'regex' },
  { value: 'exists', label: 'exists' },
]

export const OPERATORS_BY_FIELD: Record<string, FilterRule['operator'][]> = {
  has_face: ['eq', 'exists'],
  person: ['eq', 'contains', 'in', 'contains_any'],
  keywords: ['contains_any', 'contains_all', 'exists'],
}

export function getFilterOperators(field: string): { value: FilterRule['operator']; label: string }[] {
  if (OPERATORS_BY_FIELD[field]) {
    return FILTER_OPERATORS.filter((op) => OPERATORS_BY_FIELD[field].includes(op.value))
  }
  return FILTER_OPERATORS
}
