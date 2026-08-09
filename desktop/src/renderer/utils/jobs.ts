import type { AnalysisJobData, AnalysisJobStatus, AnalysisJobType } from '@gather/shared'

const CLEARABLE_STATUSES: readonly AnalysisJobStatus[] = [
  'succeeded',
  'failed',
  'cancelled',
  'interrupted',
]

// Keep aligned with JobService.CLEAR_COMPLETED_STAGE_EVIDENCE_TYPES: these
// rows are deliberately retained because workspace status derives indexed /
// exported stage evidence from them.
const STAGE_EVIDENCE_TYPES: readonly AnalysisJobType[] = [
  'metadata.scan',
  'export.execute',
]

export function isAnalysisJobClearable(
  job: Pick<AnalysisJobData, 'status' | 'type'>,
): boolean {
  return CLEARABLE_STATUSES.includes(job.status) && !STAGE_EVIDENCE_TYPES.includes(job.type)
}
