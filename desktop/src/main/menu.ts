// Application menu construction, localized per locale
// (docs/DESIGN_IMPROVEMENTS.md 4.4.2): the template is rebuilt from the
// current locale; the main process still owns no natural-language copy for
// notifications — it sends GatherErrorCode and the renderer maps them.
//
// Locale resolution lives in ./locale (pure, unit-tested): settings
// `ui_language` override wins, then `--lang` Chromium/Electron switch, then
// `app.getLocale()`; anything not zh-prefixed falls back to 'en'. Note that
// Electron/Chromium also consume `--lang` for their own UI, so the switch
// affects the app menu and Chromium's internal dialogs consistently.
//
// Language switch (i18n P2 收尾): the Settings page calls
// `settings.set_language`, whose handler persists `ui_language` and calls
// `setAppLocale()` below — the menu rebuilds immediately; the renderer
// applies the same locale via initI18n() before/after first render.

import { app, Menu } from 'electron'
import { isGatherErrorCode } from '@gather/shared'
import { getSelectedPhotos } from './capture-one'
import type { AppLocale } from './locale'

// Keep the pre-refactor public surface: main/index.ts imports these from
// './menu' (ADR-019); the implementation now lives in ./locale.
export { resolveAppLocale, type AppLocale } from './locale'

/** Event sink so menu click handlers can reach the window without importing it. */
export type MenuSend = (eventName: string, payload: unknown) => void

const isDev = !app.isPackaged && process.env.NODE_ENV !== 'production'

interface MenuLabels {
  appName: string
  file: string
  edit: string
  view: string
  window: string
  importFromCaptureOne: string
  about: string
  quit: string
  close: string
  undo: string
  redo: string
  cut: string
  copy: string
  paste: string
  selectAll: string
  reload: string
  toggleDevTools: string
  zoomIn: string
  zoomOut: string
  resetZoom: string
  minimize: string
  zoom: string
  front: string
}

const LABELS: Record<AppLocale, MenuLabels> = {
  en: {
    appName: 'Gather',
    file: 'File',
    edit: 'Edit',
    view: 'View',
    window: 'Window',
    importFromCaptureOne: 'Import from Capture One',
    about: 'About Gather',
    quit: 'Quit Gather',
    close: 'Close Window',
    undo: 'Undo',
    redo: 'Redo',
    cut: 'Cut',
    copy: 'Copy',
    paste: 'Paste',
    selectAll: 'Select All',
    reload: 'Reload',
    toggleDevTools: 'Toggle Developer Tools',
    zoomIn: 'Zoom In',
    zoomOut: 'Zoom Out',
    resetZoom: 'Actual Size',
    minimize: 'Minimize',
    zoom: 'Zoom',
    front: 'Bring All to Front',
  },
  'zh-CN': {
    appName: 'Gather',
    file: '文件',
    edit: '编辑',
    view: '视图',
    window: '窗口',
    importFromCaptureOne: '从 Capture One 导入',
    about: '关于 Gather',
    quit: '退出 Gather',
    close: '关闭窗口',
    undo: '撤销',
    redo: '重做',
    cut: '剪切',
    copy: '复制',
    paste: '粘贴',
    selectAll: '全选',
    reload: '重新加载',
    toggleDevTools: '切换开发者工具',
    zoomIn: '放大',
    zoomOut: '缩小',
    resetZoom: '实际大小',
    minimize: '最小化',
    zoom: '缩放',
    front: '全部置于顶层',
  },
}

export function buildAppMenu(locale: AppLocale, send: MenuSend): Electron.MenuItemConstructorOptions[] {
  const l = LABELS[locale]
  return [
    {
      label: l.appName,
      submenu: [
        { role: 'about', label: l.about },
        { type: 'separator' },
        { role: 'quit', label: l.quit },
      ],
    },
    {
      label: l.file,
      submenu: [
        {
          label: l.importFromCaptureOne,
          accelerator: 'CmdOrCtrl+Shift+I',
          click: async () => {
            try {
              const files = await getSelectedPhotos()
              if (files.length > 0) {
                send('c1:plugin-import', { files })
              } else {
                // getSelectedPhotos succeeded but nothing is selected: the
                // document context is unusable, so reuse the existing
                // C1_NO_DOCUMENT code — its copy ("open a directory and
                // select the photos there") is the right guidance, and the
                // code surface stays minimal.
                send('gather:notification', {
                  type: 'warning',
                  message: 'C1_NO_DOCUMENT',
                })
              }
            } catch (err) {
              console.error('Capture One import failed:', err)
              send('gather:notification', {
                type: 'error',
                message: err instanceof Error && isGatherErrorCode(err.message)
                  ? err.message
                  : 'C1_SCRIPT_FAILED',
              })
            }
          },
        },
        { type: 'separator' },
        { role: 'close', label: l.close },
      ],
    },
    {
      label: l.edit,
      submenu: [
        { role: 'undo', label: l.undo },
        { role: 'redo', label: l.redo },
        { type: 'separator' },
        { role: 'cut', label: l.cut },
        { role: 'copy', label: l.copy },
        { role: 'paste', label: l.paste },
        { role: 'selectAll', label: l.selectAll },
      ],
    },
    {
      label: l.view,
      submenu: [
        { role: 'reload', label: l.reload, visible: isDev },
        { role: 'toggleDevTools', label: l.toggleDevTools, visible: isDev },
        { type: 'separator' },
        { role: 'zoomIn', label: l.zoomIn },
        { role: 'zoomOut', label: l.zoomOut },
        { role: 'resetZoom', label: l.resetZoom },
      ],
    },
    {
      label: l.window,
      submenu: [
        { role: 'minimize', label: l.minimize },
        { role: 'zoom', label: l.zoom },
        { type: 'separator' },
        { role: 'front', label: l.front },
      ],
    },
  ]
}

let currentLocale: AppLocale = 'en'
let sendEvent: MenuSend = () => {}

/** Rebuild the application menu from the current locale. */
export function rebuildMenu(): void {
  Menu.setApplicationMenu(Menu.buildFromTemplate(buildAppMenu(currentLocale, sendEvent)))
}

/** Switch the menu locale and rebuild immediately (language-switch UI path). */
export function setAppLocale(locale: AppLocale): void {
  currentLocale = locale
  rebuildMenu()
}

/** Install the menu with its locale and event sink, then rebuild it. */
export function setupAppMenu(locale: AppLocale, send: MenuSend): void {
  currentLocale = locale
  sendEvent = send
  rebuildMenu()
}
