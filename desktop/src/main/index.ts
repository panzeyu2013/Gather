// src/main/index.ts
// Electron 主进程入口

import { app, BrowserWindow, ipcMain, Menu, dialog, session } from 'electron'
import { join, resolve } from 'path'
import { homedir } from 'os'
import { PythonBridge } from './python-bridge'
import { getSelectedPhotos, reloadMetadata } from './capture-one'
import { ALLOWED_COMMANDS, DESTRUCTIVE_COMMANDS, isRecord } from '@gather/shared'

const isDev = !app.isPackaged
const python = new PythonBridge()
let mainWindow: BrowserWindow | null = null
let quitting = false
let didSendReady = false

const WINDOW_DEFAULT_WIDTH = 1200
const WINDOW_DEFAULT_HEIGHT = 800
const WINDOW_MIN_WIDTH = 480
const WINDOW_MIN_HEIGHT = 360

function sanitizeError(err: unknown): string {
  if (err instanceof Error) return err.message.replaceAll(homedir(), '~')
  try { return JSON.stringify(err).replaceAll(homedir(), '~') } catch { return String(err) }
}

// Import from Capture One shortcut — triggered by menu accelerator CmdOrCtrl+Shift+I.
// Sends `c1:import-trigger` to renderer; the renderer then calls IPC handlers
// `c1:get-selected-photos` and `c1:reload-metadata` to fetch data from C1 via
// osascript. Only the main window's webContents is targeted; verify the source
// window if multi-window support is added in the future.
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
        click: () => mainWindow?.webContents.send('python:event', 'c1:import-trigger'),
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
    // __dirname resolves to dist/main/ in both dev and production (compiled CJS output)
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
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  mainWindow.webContents.on('will-navigate', (event) => {
    event.preventDefault()
  })

  // Deny-by-default permission policy
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

  mainWindow.webContents.once('did-finish-load', () => {
    if (python.isRunning) {
      didSendReady = true
      mainWindow?.webContents.send('python:ready')
      mainWindow?.webContents.send('python:event', 'python:ready')
    }
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

  ipcMain.handle('python:command', async (e, cmd: string, params: Record<string, unknown>) => {
    ensureMainWindowSender(e)
    if (!ALLOWED_COMMANDS.has(cmd)) throw new Error(`Rejected command: ${cmd}`)
    if (!isRecord(params)) throw new Error('Command parameters must be an object')
    if (DESTRUCTIVE_COMMANDS.has(cmd)) {
      if (params.confirmed !== true) {
        throw new Error(`Destructive command "${cmd}" requires explicit confirmation`)
      }
    }
    return python.send(cmd, params)
  })

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
}

// ── 生命周期 ──

app.enableSandbox()

app.whenReady().then(async () => {
  registerIpc()

  // 设置一次应用菜单，避免在 createWindow 重复调用
  Menu.setApplicationMenu(Menu.buildFromTemplate(appMenuTemplate))

  // 先创建窗口（带 loading），避免用户看到 dock 跳动而无窗口
  createWindow()

  // 尽早注册 activate，避免长耗时 Python 启动期间的事件丢失
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
      if (!python.isRunning) {
        didSendReady = false
        python.start('python3').then(() => {
          mainWindow?.webContents.send('python:ready')
          mainWindow?.webContents.send('python:event', 'python:ready')
        }).catch((err) => {
          console.error('Engine restart failed on activate:', err)
          dialog.showErrorBox('Engine Error', 'Failed to restart the Python engine. Please restart the application.')
        })
      }
    }
  })

  try {
    await python.start('python3')
  } catch (err: unknown) {
    console.error('[gather] Failed to start Python engine:', err)
    if (!python.isRunning && err instanceof Error && err.message.includes('exit')) {
      // If the engine exited but a restart is in progress, do not immediately exit.
      // The exit handler in python-bridge.ts handles the restart/error dialog path.
      return
    }
    dialog.showErrorBox('Startup Failed', `Cannot start Python engine:\n${sanitizeError(err)}`)
    app.exit(1)
    return
  }

  if (!didSendReady) {
    mainWindow?.webContents.send('python:ready')
  }
  mainWindow?.webContents.send('python:event', 'python:ready')
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('before-quit', (event) => {
  if (quitting) return
  quitting = true
  if (!python.isRunning && !(python as unknown as { proc: unknown }).proc) {
    app.exit(0)
    return
  }
  event.preventDefault()
  python.kill()
  setTimeout(() => {
    python.forceKill()
    app.exit(0)
  }, 5000)
})

app.on('will-quit', () => {
  python.forceKill()
})

// 确保单实例
const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  })
}
