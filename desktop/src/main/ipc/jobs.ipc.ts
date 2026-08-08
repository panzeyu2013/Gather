import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { JobService } from '../services/jobs/job.service'
import type { AnalysisJobStatus } from '@gather/shared'

export function registerJobHandlers(registry: CommandRegistry, jobs: JobService): void {
  registry.register('jobs.list', wrapHandler(async (params) => {
    const status = params.status === undefined ? undefined : validateString(params.status, 'status') as AnalysisJobStatus
    return ok(jobs.list(status))
  }))
  registry.register('jobs.cancel', wrapHandler(async (params) => ok(jobs.cancel(validateString(params.jobId, 'jobId')))))
  registry.register('jobs.retry', wrapHandler(async (params) => ok(jobs.retry(validateString(params.jobId, 'jobId')))))
  registry.register('jobs.clear_completed', wrapHandler(async (params) => {
    if (params.confirmed !== true) throw new Error('JOBS_CLEAR_CONFIRM_REQUIRED')
    // Stage-evidence rows (metadata.scan / export.execute) are excluded inside
    // JobService.clearCompleted: deleting them would regress workspace stage
    // (indexed→imported) and the exported soft flag (see job.service.ts).
    return ok(jobs.clearCompleted())
  }))
}
