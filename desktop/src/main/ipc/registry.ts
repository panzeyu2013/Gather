import { ipcMain } from 'electron'
import type { Command } from '@gather/shared'

type CommandHandler = (params: unknown, event?: Electron.IpcMainInvokeEvent) => Promise<unknown>
type CommandType = Command['type']

export class CommandRegistry {
  private handlers = new Map<CommandType, CommandHandler>()

  register(type: CommandType, handler: CommandHandler): void {
    this.handlers.set(type, handler)
  }

  async execute(type: CommandType, params: unknown, event?: Electron.IpcMainInvokeEvent): Promise<unknown> {
    const handler = this.handlers.get(type)
    if (!handler) throw new Error(`Unknown command: ${type}`)
    return handler(params, event)
  }
}

export function registerAllIpcHandlers(
  registry: CommandRegistry,
  validateSender?: (event: Electron.IpcMainInvokeEvent) => void,
): void {
  ipcMain.handle('gather:command', async (event, cmd: CommandType, params: unknown) => {
    validateSender?.(event)
    return registry.execute(cmd, params, event)
  })
}
