import type { CommandRegistry } from './registry'
import type { ExportProgressEvent } from '@gather/shared'
import { ok, err, validateString, wrapHandler } from './helpers'
import { ExportService } from '../services/export/export.service'
import { ReportService } from '../services/export/report.service'
import { getServices } from '../bootstrap'

export function registerExportHandlers(registry: CommandRegistry): void {
  const { exportService, reportService } = getServices()
  registry.register(
    'export.preview',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = params.options as Record<string, unknown>
      if (!options || typeof options !== 'object') {
        throw new Error('Invalid options: must be an object')
      }
      const preview = await exportService.preview(sessionId, options as unknown as Parameters<ExportService['preview']>[1])
      return ok(preview)
    }),
  )

  registry.register(
    'export.execute',
    wrapHandler(async (params, event) => {
      if (params.confirmed !== true) {
        throw new Error('Export requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = params.options as Record<string, unknown>
      if (!options || typeof options !== 'object') {
        throw new Error('Invalid options: must be an object')
      }
      const result = await exportService.execute(
        sessionId,
        options as unknown as Parameters<ExportService['execute']>[1],
        (e: ExportProgressEvent) => {
          event?.sender.send('gather:event', 'export:progress', {
            ...e,
            sessionId,
          })
        },
      )
      return ok(result)
    }),
  )

  registry.register(
    'export.cancel',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      exportService.cancel(sessionId)
      return ok(true)
    }),
  )

  registry.register(
    'export.report',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const reportType = validateString(params.reportType, 'reportType')
      const format = typeof params.format === 'string' ? params.format : undefined

      if (['person', 'keyword'].includes(reportType)) {
        const content = reportType === 'person'
          ? reportService.generatePersonReport(sessionId)
          : reportService.generateKeywordReport(sessionId)
        const reportFormat = (format === 'csv' ? 'csv' : 'md') as 'csv' | 'md'
        return ok({ path: '', content, format: reportFormat })
      }
      const report = await exportService.generateReport(sessionId, reportType, format)
      return ok(report)
    }),
  )
}
