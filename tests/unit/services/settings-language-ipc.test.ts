import { beforeEach, describe, expect, it, vi } from 'vitest'

const { setAppLocale } = vi.hoisted(() => ({ setAppLocale: vi.fn() }))

vi.mock('electron', () => ({
  app: {
    commandLine: { getSwitchValue: () => '' },
    getLocale: () => 'zh-CN',
  },
  ipcMain: { handle: vi.fn() },
}))

vi.mock('../../../desktop/src/main/menu', () => ({ setAppLocale }))

vi.mock('../../../desktop/src/main/services/face-kw/provider', () => ({
  getAutoBackend: vi.fn(),
  getAutoBackendLabel: vi.fn(),
  getAvailableBackends: vi.fn(),
  getFaceModelPresence: vi.fn(),
  getModelResourcesDir: vi.fn(),
}))

import { CommandRegistry } from '../../../desktop/src/main/ipc/registry'
import { registerSettingsHandlers } from '../../../desktop/src/main/ipc/settings.ipc'
import type { SettingsService } from '../../../desktop/src/main/services/settings/settings.service'

describe('settings.reset locale synchronization', () => {
  beforeEach(() => setAppLocale.mockClear())

  it('rebuilds the menu using the effective system locale after clearing the override', async () => {
    const values: Record<string, string> = { ui_language: 'en' }
    const service = {
      reset: () => { values.ui_language = '' },
      get: (key: string, fallback = '') => values[key] ?? fallback,
      getAll: () => ({ ...values }),
    } as unknown as SettingsService
    const registry = new CommandRegistry()
    registerSettingsHandlers(registry, service)

    await expect(registry.execute('settings.reset', {})).resolves.toEqual({
      ok: true,
      data: { ui_language: '' },
    })
    expect(setAppLocale).toHaveBeenCalledOnce()
    expect(setAppLocale).toHaveBeenCalledWith('zh-CN')
  })
})
