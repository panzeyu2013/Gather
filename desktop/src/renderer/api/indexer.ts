import type { AnalysisJobData } from '@gather/shared'
import { sendCommand } from './client'

export const indexerApi = {
  scan: (sessionId: string) =>
    sendCommand<AnalysisJobData>('index.scan', { sessionId }),
}
