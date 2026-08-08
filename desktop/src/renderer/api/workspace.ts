import { sendCommand } from './client'
import type { WorkspaceStatus } from '@gather/shared'

export const workspaceApi = {
  status: (sessionId: string) =>
    sendCommand<WorkspaceStatus>('workspace.status', { sessionId }),
}
