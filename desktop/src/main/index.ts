// src/main/index.ts
// Electron 主进程入口 — 新架构

import { app, BrowserWindow, ipcMain, Menu, dialog, session } from 'electron'
import { join, resolve } from 'path'
import { readdirSync, statSync } from 'fs'
import { getSelectedPhotos, reloadMetadata } from './capture-one'
import { getDatabase } from './db/database'
import { SettingsService } from './services/settings'
import { runMigrations } from './db/migrations'
import { CommandRegistry, registerAllIpcHandlers } from './ipc/registry'
import { registerSessionHandlers } from './ipc/session.ipc'
import { registerFaceKwHandlers } from './ipc/face-kw.ipc'
import { registerSimilarityHandlers } from './ipc/similarity.ipc'
import { registerWritebackHandlers } from './ipc/writeback.ipc'
import { registerSystemHandlers } from './ipc/system.ipc'
import { registerImageHandlers } from './ipc/image.ipc'
import { registerPhotoHandlers } from './ipc/photo.ipc'
import { registerSettingsHandlers } from './ipc/settings.ipc'

const isDev = !app.isPackaged && process.env.NODE_ENV !== 'production'
const registry = new CommandRegistry()
let mainWindow: BrowserWindow | null = null

function handleDeepLink(url: string): void {
  try {
    const parsed = new URL(url)
    if (parsed.hostname !== 'import') return
    const files = parsed.searchParams.getAll('file').map(f => decodeURIComponent(f)).filter(Boolean)
    if (files.length === 0) return
    mainWindow?.webContents.send('gather:event', 'c1:plugin-import', { files })
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  } catch {
    console.error('Failed to parse deep link:', url)
  }
}

const WINDOW_DEFAULT_WIDTH = 1200
const WINDOW_DEFAULT_HEIGHT = 800
const WINDOW_MIN_WIDTH = 480
const WINDOW_MIN_HEIGHT = 360

const appMenuTemplate: Electron.MenuItemConstructorOptions[] = [
  {
    label: 'Gather',
    submenu: [
      { role: 'about' },
      { type: 'separator' },
      { role: 'quit' },
    ],
  },
  {
    label: 'File',
    submenu: [
      {
        label: 'Import from Capture One',
        accelerator: 'CmdOrCtrl+Shift+I',
        click: () => mainWindow?.webContents.send('gather:event', 'c1:import-trigger', { photoCount: 0 }),
      },
      { type: 'separator' },
      { role: 'close' },
    ],
  },
  {
    label: 'Edit',
    submenu: [
      { role: 'undo' },
      { role: 'redo' },
      { type: 'separator' },
      { role: 'cut' },
      { role: 'copy' },
      { role: 'paste' },
      { role: 'selectAll' },
    ],
  },
  {
    label: 'View',
    submenu: [
      { role: 'reload', visible: isDev },
      { role: 'toggleDevTools', visible: isDev },
      { type: 'separator' },
      { role: 'zoomIn' },
      { role: 'zoomOut' },
      { role: 'resetZoom' },
    ],
  },
  {
    label: 'Window',
    submenu: [
      { role: 'minimize' },
      { role: 'zoom' },
      { type: 'separator' },
      { role: 'front' },
    ],
  },
]

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: WINDOW_DEFAULT_WIDTH,
    height: WINDOW_DEFAULT_HEIGHT,
    minWidth: WINDOW_MIN_WIDTH,
    minHeight: WINDOW_MIN_HEIGHT,
    title: 'Gather',
    show: false,
    backgroundColor: '#1a1a2e',
    webPreferences: {
      preload: resolve(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })

  if (isDev) {
    mainWindow.loadURL('http://localhost:5173')
  } else {
    mainWindow.loadFile(join(__dirname, '../../renderer/index.html'))
  }

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  mainWindow.webContents.on('will-navigate', (event) => {
    event.preventDefault()
  })

  session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback, _details) => {
    callback(false)
  })

  session.defaultSession.webRequest.onHeadersReceived({ urls: ['*://*/*', 'file://*'] }, (details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [
          isDev
            ? "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
            : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        ]
      }
    });
  });

  mainWindow.once('ready-to-show', () => {
    mainWindow?.show()
  })

  mainWindow.webContents.on('did-finish-load', () => {
    mainWindow?.webContents.send('gather:event', 'engine:status', { status: 'ready' })
  })

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

// ── IPC 处理 ──

function registerIpc(): void {
  const ensureMainWindowSender = (e: Electron.IpcMainInvokeEvent): void => {
    if (!mainWindow || e.sender !== mainWindow.webContents) {
      throw new Error('This action is only available from the main application window')
    }
  }

  registerAllIpcHandlers(registry)
  registerSessionHandlers(registry)
  registerFaceKwHandlers(registry)
  registerSimilarityHandlers(registry)
  registerWritebackHandlers(registry)
  registerSystemHandlers(registry)
  registerImageHandlers(registry)
  registerPhotoHandlers(registry)
  registerSettingsHandlers(registry)

  ipcMain.handle('c1:get-selected-photos', async (e) => {
    ensureMainWindowSender(e)
    return getSelectedPhotos()
  })

  ipcMain.handle('c1:reload-metadata', async (e) => {
    ensureMainWindowSender(e)
    return reloadMetadata()
  })

  ipcMain.handle('app:version', (e) => {
    ensureMainWindowSender(e)
    return app.getVersion()
  })

  ipcMain.handle('app:select-directory', async (e) => {
    ensureMainWindowSender(e)
    if (!mainWindow) throw new Error('No window')
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory'],
      title: 'Select photo directory',
    })
    return result.canceled ? null : result.filePaths[0]
  })

  ipcMain.handle('app:select-files', async (e) => {
    ensureMainWindowSender(e)
    if (!mainWindow) throw new Error('No window')
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openFile', 'multiSelections'],
      title: 'Select photos',
      filters: [
        { name: 'Photos', extensions: ['jpg', 'jpeg', 'png', 'tif', 'tiff', 'arw', 'cr2', 'cr3', 'nef', 'dng', 'raf'] },
      ],
    })
    return result.canceled ? [] : result.filePaths
  })

  ipcMain.handle('app:scan-directory', async (e, dirPath: string) => {
    ensureMainWindowSender(e)
    if (!mainWindow) throw new Error('No window')
    if (typeof dirPath !== 'string' || dirPath.length === 0) {
      throw new Error('Invalid directory path')
    }
    const extensions = new Set(['.jpg', '.jpeg', '.png', '.tif', '.tiff', '.arw', '.cr2', '.cr3', '.nef', '.dng', '.raf'])
    const files: string[] = []
    try {
      const entries = readdirSync(dirPath)
      for (const entry of entries) {
        const fullPath = join(dirPath, entry)
        try {
          const stat = statSync(fullPath)
          if (stat.isFile()) {
            const ext = '.' + entry.split('.').pop()?.toLowerCase()
            if (extensions.has(ext)) {
              files.push(fullPath)
            }
          }
        } catch {
          // skip unreadable entries
        }
      }
    } catch {
      throw new Error('Failed to read directory')
    }
    return files
  })
}

// ── 生命周期 ──

app.enableSandbox()

app.whenReady().then(() => {
  const db = getDatabase()
  runMigrations(db)

  registerIpc()

  const settings = SettingsService.getInstance()
  db.pragma(`synchronous = ${settings.get('db_synchronous', 'normal').toUpperCase()}`)
  db.pragma(`cache_size = ${-settings.getNumber('db_cache_size_mb', 64) * 1000}`)

  Menu.setApplicationMenu(Menu.buildFromTemplate(appMenuTemplate))
  createWindow()

  if (!app.isDefaultProtocolClient('gather')) {
    app.setAsDefaultProtocolClient('gather')
  }

  app.on('open-url', (event, url) => {
    event.preventDefault()
    handleDeepLink(url)
  })

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', (_event, argv) => {
    const url = argv.find(arg => arg.startsWith('gather://'))
    if (url) handleDeepLink(url)
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  })
}
