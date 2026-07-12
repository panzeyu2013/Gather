import { sendCommand } from './client'
import type { ExportPreview, ExportResult, ExportOptions, ReportData } from '@gather/shared'

export const exportApi = {
  preview: (sessionId: string, options: ExportOptions) =>
    sendCommand<ExportPreview>('export.preview', { sessionId, options }),

  execute: (sessionId: string, options: ExportOptions) =>
    sendCommand<ExportResult>('export.execute', { sessionId, options, confirmed: true }),

  cancel: (sessionId: string) =>
    sendCommand<boolean>('export.cancel', { sessionId }),

  report: (sessionId: string, reportType: string, format?: string) =>
    sendCommand<ReportData>('export.report', { sessionId, reportType, format }),
}
