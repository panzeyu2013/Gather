import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { WorkspaceStatusService } from '../services/workspace/workspace-status.service'

export function registerWorkspaceHandlers(
  registry: CommandRegistry,
  workspaceStatus: WorkspaceStatusService,
): void {
  registry.register(
    'workspace.status',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const status = workspaceStatus.getStatus(sessionId)
      if (!status) return err('SESSION_NOT_FOUND')
      return ok(status)
    }),
  )
}
