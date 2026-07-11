import { sendCommand } from './client'

export const settingsApi = {
  getAll: () => sendCommand<Record<string, string>>('settings.get_all', {}),
  get: (key: string) => sendCommand<string>('settings.get', { key }),
  set: (key: string, value: string) => sendCommand<{ done: boolean }>('settings.set', { key, value }),
  reset: () => sendCommand<Record<string, string>>('settings.reset', {}),
}
