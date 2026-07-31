import type { AnalysisJobData, AnalysisJobStatus } from '@gather/shared'
import { sendCommand } from './client'

export const jobsApi = {
  list: (status?: AnalysisJobStatus) => sendCommand<AnalysisJobData[]>('jobs.list', { status }),
  cancel: (jobId: string) => sendCommand<boolean>('jobs.cancel', { jobId }),
  retry: (jobId: string) => sendCommand<boolean>('jobs.retry', { jobId }),
  clearCompleted: () => sendCommand<number>('jobs.clear_completed', { confirmed: true }),
}
