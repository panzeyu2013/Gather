import type { AnalysisJobData, QualityResult } from '@gather/shared'
import { sendCommand } from './client'

export const qualityApi = {
  analyze: (sessionId: string, photoIds?: string[]) =>
    sendCommand<AnalysisJobData>('quality.analyze', { sessionId, photoIds }),
  get: (sessionId: string, photoIds?: string[]) =>
    sendCommand<QualityResult[]>('quality.get', { sessionId, photoIds }),
}
