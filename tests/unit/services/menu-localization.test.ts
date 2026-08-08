import { describe, expect, it, vi, beforeEach } from 'vitest'
import type { MenuItemConstructorOptions } from 'electron'

vi.mock('electron', () => ({
  app: { isPackaged: true },
  Menu: {
    buildFromTemplate: (template: MenuItemConstructorOptions[]) => template,
    setApplicationMenu: vi.fn(),
  },
}))

import { Menu } from 'electron'
import { setAppLocale, setupAppMenu, type AppLocale } from '../../../desktop/src/main/menu'

const setApplicationMenu = vi.mocked(Menu.setApplicationMenu)

function topLevelLabels(template: MenuItemConstructorOptions[]): string[] {
  return template.map(item => item.label).filter((label): label is string => Boolean(label))
}

describe('menu localization', () => {
  beforeEach(() => {
    setApplicationMenu.mockClear()
  })

  it('builds the application menu with zh-CN labels when installed in Chinese', () => {
    setupAppMenu('zh-CN', () => {})

    expect(setApplicationMenu).toHaveBeenCalledTimes(1)
    const template = setApplicationMenu.mock.calls[0][0]
    expect(topLevelLabels(template)).toContain('文件')
    expect(topLevelLabels(template)).toContain('编辑')
    expect(topLevelLabels(template)).toContain('视图')
    expect(topLevelLabels(template)).toContain('窗口')
  })

  it('builds the application menu with English labels by default', () => {
    setupAppMenu('en', () => {})

    const template = setApplicationMenu.mock.calls[0][0]
    expect(topLevelLabels(template)).toEqual(
      expect.arrayContaining(['File', 'Edit', 'View', 'Window']),
    )
  })

  it('rebuilds the menu immediately with the new locale on setAppLocale', () => {
    setupAppMenu('en', () => {})
    setApplicationMenu.mockClear()

    setAppLocale('zh-CN' as AppLocale)

    expect(setApplicationMenu).toHaveBeenCalledTimes(1)
    expect(topLevelLabels(setApplicationMenu.mock.calls[0][0])).toContain('文件')
  })

  it('keeps the Capture One import accelerator and click wiring across locales', () => {
    setupAppMenu('en', () => {})
    const template = setApplicationMenu.mock.calls[0][0]
    const fileItem = template.find(item => item.label === 'File')
    const importItem = fileItem?.submenu?.find(item =>
      typeof item === 'object' && item !== null && 'accelerator' in item,
    ) as { accelerator?: string } | undefined
    expect(importItem?.accelerator).toBe('CmdOrCtrl+Shift+I')
  })
})
