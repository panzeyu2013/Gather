import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import { getServices } from '../bootstrap'

export function registerHistoryHandlers(registry: CommandRegistry): void {
  const { historyService } = getServices()
  registry.register(
    'history.list',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const limit = typeof params.limit === 'number' ? params.limit : 50
      const offset = typeof params.offset === 'number' ? params.offset : 0
      const entries = await historyService.list(sessionId, limit, offset)
      return ok(entries)
    }),
  )

  registry.register(
    'history.undo',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('history.undo requires confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const operationId = typeof params.operationId === 'number' ? params.operationId : undefined
      await historyService.undo(sessionId, operationId)
      return ok(true)
    }),
  )

  registry.register(
    'history.redo',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('history.redo requires confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      await historyService.redo(sessionId)
      return ok(true)
    }),
  )

  registry.register(
    'history.can_undo',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const status = await historyService.canUndo(sessionId)
      return ok(status)
    }),
  )

  registry.register(
    'history.can_redo',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const status = await historyService.canRedo(sessionId)
      return ok(status)
    }),
  )
}
