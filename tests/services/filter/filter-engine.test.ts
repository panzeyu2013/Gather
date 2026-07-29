import { describe, expect, it } from 'vitest'
import type { FilterGroup } from '@gather/shared'
import { FilterEngine } from '../../../desktop/src/main/services/filter/filter-engine'
import { FILTER_OPERATORS } from '../../../desktop/src/renderer/components/FilterBar/filter-constants'

describe('filter operator safety', () => {
  it('does not expose regular expressions in the filter UI', () => {
    expect(FILTER_OPERATORS.map((operator) => operator.value)).not.toContain(
      'regex',
    )
  })

  it('rejects legacy or forged regular-expression filters', () => {
    const engine = new FilterEngine(null as never)
    const criteria = {
      logic: 'and',
      conditions: [
        {
          field: 'filename',
          operator: 'regex',
          value: '(a+)+$',
        },
      ],
    } as unknown as FilterGroup

    expect(() => engine.buildWhereClause(criteria)).toThrow(
      'Unsupported filter operator: regex',
    )
  })
})
