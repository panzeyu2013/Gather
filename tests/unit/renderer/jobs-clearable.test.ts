import { describe, expect, it } from 'vitest'
import { isAnalysisJobClearable } from '../../../desktop/src/renderer/utils/jobs'

describe('isAnalysisJobClearable', () => {
  it.each(['succeeded', 'failed', 'cancelled', 'interrupted'] as const)(
    'allows non-evidence jobs in terminal status %s',
    (status) => {
      expect(isAnalysisJobClearable({ type: 'duplicate.scan', status })).toBe(true)
    },
  )

  it.each(['queued', 'running', 'cancelling'] as const)(
    'rejects active status %s',
    (status) => {
      expect(isAnalysisJobClearable({ type: 'duplicate.scan', status })).toBe(false)
    },
  )

  it.each(['metadata.scan', 'export.execute'] as const)(
    'retains workspace-stage evidence rows of type %s',
    (type) => {
      expect(isAnalysisJobClearable({ type, status: 'failed' })).toBe(false)
      expect(isAnalysisJobClearable({ type, status: 'succeeded' })).toBe(false)
    },
  )
})
