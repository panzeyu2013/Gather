import { ipcMain } from 'electron'

type CommandHandler = (params: unknown, event?: Electron.IpcMainInvokeEvent) => Promise<unknown>

export class CommandRegistry {
  private handlers = new Map<string, CommandHandler>()

  register(type: string, handler: CommandHandler): void {
    this.handlers.set(type, handler)
  }

  async execute(type: string, params: unknown, event?: Electron.IpcMainInvokeEvent): Promise<unknown> {
    const handler = this.handlers.get(type)
    if (!handler) throw new Error(`Unknown command: ${type}`)
    return handler(params, event)
  }
}

export function registerAllIpcHandlers(registry: CommandRegistry): void {
  ipcMain.handle('gather:command', async (_event, cmd: string, params: unknown) => {
    return registry.execute(cmd, params, _event)
  })
}
