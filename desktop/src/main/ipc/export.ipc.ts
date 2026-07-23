import type { CommandRegistry } from './registry'
import type { ExportProgressEvent } from '@gather/shared'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { ExportService } from '../services/export/export.service'
import type { ReportService } from '../services/export/report.service'

export function registerExportHandlers(registry: CommandRegistry, exportService: ExportService, reportService: ReportService): void {
  registry.register(
    'export.preview',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = params.options as Record<string, unknown>
      if (!options || typeof options !== 'object') {
        return err('Invalid export options')
      }
      const preview = exportService.preview(sessionId, options as unknown as Parameters<typeof exportService.preview>[1])
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
        return err('Invalid export options')
      }
      const onProgress = (e: ExportProgressEvent) => {
        event?.sender.send('gather:event', 'export:progress', e)
      }
      const result = await exportService.execute(sessionId, options as unknown as Parameters<typeof exportService.execute>[1], onProgress)
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
      const reportType = typeof params.reportType === 'string' ? params.reportType : 'session_summary'
      const format = typeof params.format === 'string' ? params.format : undefined
      return ok(exportService.generateReport(sessionId, reportType, format))
    }),
  )
}
