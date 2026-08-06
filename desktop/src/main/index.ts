import { app, BrowserWindow, ipcMain, Menu, dialog, protocol, session, shell } from 'electron'
import { join, resolve } from 'path'
import { readdir, stat } from 'fs/promises'
import { getSelectedPhotos, reloadMetadata } from './capture-one'
import { Database } from './db/database'
import { runMigrations } from './db/migrations'
import { initContainer, getService } from './di/init'
import { DI_TOKENS } from './di/container'
import { SettingsService } from './services/settings/settings.service'
import { SessionService } from './services/session/session.service'
import { FaceKwService } from './services/face-kw/face-kw.service'
import { FaceRepository } from './db/repositories/face.repo'
import { WritebackService } from './services/writeback/writeback.service'
import { SimilarityService } from './services/similarity/similarity.service'
import { ImageService, type ThumbnailCache } from './services/image'
import { PhotoRepository } from './db/repositories/photo.repo'
import { AssetRepository } from './db/repositories/asset.repo'
import { FilterEngine } from './services/filter/filter-engine'
import { SmartAlbumRepository } from './db/repositories/smart-album.repo'
import { DuplicateService } from './services/duplicate/duplicate.service'
import { TemplateService } from './services/template/template.service'
import { PersonRepository } from './db/repositories/person.repo'
import { MetadataService } from './services/metadata/metadata.service'
import { CullingService } from './services/culling/culling.service'
import { ExportService } from './services/export/export.service'
import { ReportService } from './services/export/report.service'
import { MetadataWriterRouter } from './services/xmp/metadata-writer-router'
import {
  shutdownRuntime,
  type RuntimeLifecycle,
} from './services/runtime/runtime-lifecycle'
import { MetadataSyncCoordinator } from './services/metadata/metadata-sync-coordinator'
import { IMAGE_CONFIG } from './services/image/image-config'

import { CommandRegistry, registerAllIpcHandlers } from './ipc/registry'
import { registerSessionHandlers } from './ipc/session.ipc'
import { registerFaceKwHandlers } from './ipc/face-kw.ipc'
import { registerSimilarityHandlers } from './ipc/similarity.ipc'
import { registerImageHandlers } from './ipc/image.ipc'
import { registerPhotoHandlers } from './ipc/photo.ipc'
import { registerSettingsHandlers } from './ipc/settings.ipc'
import { registerFilterHandlers, registerAlbumHandlers } from './ipc/filter.ipc'
import { registerDuplicateHandlers } from './ipc/duplicate.ipc'
import { registerTemplateHandlers } from './ipc/template.ipc'
import { registerPersonHandlers } from './ipc/person.ipc'
import { registerMetadataHandlers } from './ipc/metadata.ipc'
import { registerCullingHandlers } from './ipc/culling.ipc'
import { registerExportHandlers } from './ipc/export.ipc'
import { registerJobHandlers } from './ipc/jobs.ipc'
import { JobService } from './services/jobs/job.service'
import { IndexService } from './services/indexer/index.service'
import { registerIndexerHandlers } from './ipc/indexer.ipc'
import { registerQualityHandlers } from './ipc/quality.ipc'
import { registerNavigationHandlers } from './ipc/navigation.ipc'
import { registerAssetHandlers } from './ipc/assets.ipc'
import { QualityService } from './services/quality/quality.service'
import { NavigationService } from './services/navigation/navigation.service'
import { parseImportDeepLink } from './deep-link'
import { normalizeDatabaseRuntimeSettings } from './runtime-settings'

const isDev = !app.isPackaged && process.env.NODE_ENV !== 'production'
const registry = new CommandRegistry()
let mainWindow: BrowserWindow | null = null
let rendererReady = false
const pendingDeepLinks: string[] = []
const supportedImageExtensions = [...new Set(IMAGE_CONFIG.sharp.supportedExtensions)]
const supportedImageExtensionSet = new Set(supportedImageExtensions)

protocol.registerSchemesAsPrivileged([
  {
    scheme: 'gather-image',
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      stream: true,
    },
  },
])

function handleDeepLink(url: string): void {
  try {
    const validFiles = parseImportDeepLink(url, supportedImageExtensionSet)
    if (validFiles.length === 0) return
    if (mainWindow && rendererReady) {
      mainWindow.webContents.send('gather:event', 'c1:plugin-import', { files: validFiles })
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    } else {
      pendingDeepLinks.push(url)
    }
  } catch {
    console.error('Failed to parse deep link:', url)
  }
}

// macOS may deliver open-url before app.whenReady(). Register this listener
// during module initialization and defer delivery until the renderer exists.
app.on('open-url', (event, url) => {
  event.preventDefault()
  handleDeepLink(url)
})

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
        click: async () => {
          try {
            const files = await getSelectedPhotos()
            if (files.length > 0) {
              mainWindow?.webContents.send('gather:event', 'c1:plugin-import', { files })
            } else {
              mainWindow?.webContents.send('gather:event', 'gather:notification', {
                type: 'warning',
                message: 'No photos selected in Capture One.',
              })
            }
          } catch (err) {
            console.error('Capture One import failed:', err)
            mainWindow?.webContents.send('gather:event', 'gather:notification', {
              type: 'error',
              message: err instanceof Error
                ? `Capture One import failed: ${err.message}`
                : 'Capture One import failed. Is Capture One running?',
            })
          }
        },
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
  rendererReady = false
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
            ? "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: gather-image:; connect-src 'self' gather-image: ws:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
            : "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: gather-image:; connect-src 'self' gather-image:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        ]
      }
    });
  });

  mainWindow.once('ready-to-show', () => {
    mainWindow?.show()
  })

  mainWindow.webContents.on('did-finish-load', () => {
    rendererReady = false
  })

  mainWindow.on('closed', () => {
    rendererReady = false
    mainWindow = null
  })
}

function svc<T>(token: symbol): T {
  return getService<T>(token)
}

function registerIpc(): void {
  const db = svc<Database>(DI_TOKENS.DB)
  const settingsService = svc<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
  const sessionService = svc<SessionService>(DI_TOKENS.SESSION_SERVICE)
  const faceKwService = svc<FaceKwService>(DI_TOKENS.FACE_KW_SERVICE)
  const faceRepo = svc<FaceRepository>(DI_TOKENS.FACE_REPO)
  const writebackService = svc<WritebackService>(DI_TOKENS.WRITEBACK_SERVICE)
  const similarityService = svc<SimilarityService>(DI_TOKENS.SIMILARITY_SERVICE)
  const imageService = svc<ImageService>(DI_TOKENS.IMAGE_SERVICE)
  const photoRepo = svc<PhotoRepository>(DI_TOKENS.PHOTO_REPO)
  const assetRepo = svc<AssetRepository>(DI_TOKENS.ASSET_REPO)
  const filterEngine = svc<FilterEngine>(DI_TOKENS.FILTER_ENGINE)
  const smartAlbumRepo = svc<SmartAlbumRepository>(DI_TOKENS.SMART_ALBUM_REPO)
  const duplicateService = svc<DuplicateService>(DI_TOKENS.DUPLICATE_SERVICE)
  const templateService = svc<TemplateService>(DI_TOKENS.TEMPLATE_SERVICE)
  const personRepo = svc<PersonRepository>(DI_TOKENS.PERSON_REPO)
  const metadataService = svc<MetadataService>(DI_TOKENS.METADATA_SERVICE)
  const cullingService = svc<CullingService>(DI_TOKENS.CULLING_SERVICE)
  const exportService = svc<ExportService>(DI_TOKENS.EXPORT_SERVICE)
  const reportService = svc<ReportService>(DI_TOKENS.REPORT_SERVICE)
  const metadataSync = svc<MetadataSyncCoordinator>(DI_TOKENS.METADATA_SYNC_COORDINATOR)
  assetRepo.setMetadataRelocationSink(xmpPath => metadataSync.schedule(xmpPath, 0))
  const ensureMainWindowSender = (e: Electron.IpcMainInvokeEvent): void => {
    if (!mainWindow || e.sender !== mainWindow.webContents) {
      throw new Error('This action is only available from the main application window')
    }
  }

  registerAllIpcHandlers(registry, ensureMainWindowSender)
  registerSessionHandlers(registry, sessionService)
  registerFaceKwHandlers(
    registry,
    faceKwService,
    writebackService,
    faceRepo,
    settingsService,
    svc<JobService>(DI_TOKENS.JOB_SERVICE),
  )
  registerSimilarityHandlers(
    registry,
    similarityService,
    writebackService,
    settingsService,
    svc<JobService>(DI_TOKENS.JOB_SERVICE),
  )
  registerImageHandlers(
    registry,
    imageService,
    settingsService,
    svc<JobService>(DI_TOKENS.JOB_SERVICE),
  )
  registerPhotoHandlers(registry, photoRepo, db)
  registerAssetHandlers(registry, assetRepo)
  registerSettingsHandlers(registry, settingsService)
  registerFilterHandlers(registry, filterEngine)
  registerAlbumHandlers(registry, filterEngine, smartAlbumRepo)
  registerDuplicateHandlers(
    registry,
    duplicateService,
    svc<JobService>(DI_TOKENS.JOB_SERVICE),
  )
  registerTemplateHandlers(registry, templateService)
  registerPersonHandlers(registry, personRepo)
  registerMetadataHandlers(registry, metadataService, metadataSync)
  registerCullingHandlers(registry, cullingService, writebackService, metadataSync)
  registerExportHandlers(
    registry,
    exportService,
    reportService,
    svc<JobService>(DI_TOKENS.JOB_SERVICE),
  )
  registerJobHandlers(registry, svc<JobService>(DI_TOKENS.JOB_SERVICE))
  registerIndexerHandlers(
    registry,
    svc<IndexService>(DI_TOKENS.INDEX_SERVICE),
    svc<JobService>(DI_TOKENS.JOB_SERVICE),
    metadataService,
    photoRepo,
    assetRepo,
  )
  registerQualityHandlers(registry, svc<QualityService>(DI_TOKENS.QUALITY_SERVICE), svc<JobService>(DI_TOKENS.JOB_SERVICE))
  registerNavigationHandlers(registry, svc<NavigationService>(DI_TOKENS.NAVIGATION_SERVICE))

  ipcMain.handle('c1:get-selected-photos', async (e) => {
    ensureMainWindowSender(e)
    return getSelectedPhotos()
  })

  ipcMain.handle('c1:reload-metadata', async (e) => {
    ensureMainWindowSender(e)
    return reloadMetadata()
  })

  ipcMain.handle('app:renderer-ready', (e) => {
    ensureMainWindowSender(e)
    rendererReady = true
    mainWindow?.webContents.send('gather:event', 'engine:status', { status: 'ready' })
    for (const deepLink of pendingDeepLinks.splice(0)) {
      handleDeepLink(deepLink)
    }
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
        { name: 'Photos', extensions: supportedImageExtensions.map((extension) => extension.slice(1)) },
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
    const files: string[] = []
    // Bound the walk so scanning a huge tree cannot exhaust the main-process
    // memory with an unbounded file list returned over IPC.
    const MAX_SCANNED_FILES = 50_000
    const scan = async (directory: string): Promise<void> => {
      const entries = await readdir(directory, { withFileTypes: true })
      for (const entry of entries) {
        if (files.length >= MAX_SCANNED_FILES) return
        // Do not follow symlinks: a link may escape the selected directory or
        // introduce a directory cycle.
        if (entry.isSymbolicLink()) continue
        const fullPath = join(directory, entry.name)
        try {
          if (entry.isDirectory()) {
            await scan(fullPath)
          } else if (entry.isFile()) {
            const ext = '.' + entry.name.split('.').pop()?.toLowerCase()
            if (supportedImageExtensionSet.has(ext)) files.push(fullPath)
          }
        } catch {
          // One unreadable child must not discard the rest of the selected
          // directory. A failure at the root is still reported below.
        }
      }
    }
    try {
      const root = await stat(dirPath)
      if (!root.isDirectory()) throw new Error('Not a directory')
      await scan(dirPath)
    } catch {
      throw new Error('Failed to read directory')
    }
    return files
  })

  ipcMain.handle('app:open-directory', async (e, dirPath: string) => {
    ensureMainWindowSender(e)
    if (typeof dirPath !== 'string' || dirPath.length === 0) throw new Error('Invalid directory path')
    await shell.openPath(dirPath)
  })

  ipcMain.handle('models.download_default', async (e) => {
    ensureMainWindowSender(e)
    const settings = svc<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
    const getUrl = (key: string) => settings.get(key, '')
    const { downloadDefaultModels } = await import('./services/face-kw/model-downloader')
    await downloadDefaultModels(getUrl, (progress) => {
      mainWindow?.webContents.send('gather:event', 'models:download-progress', progress)
    })
  })
}

function registerImageProtocol(): void {
  const imageService = svc<ImageService>(DI_TOKENS.IMAGE_SERVICE)
  const photoRepo = svc<PhotoRepository>(DI_TOKENS.PHOTO_REPO)
  protocol.handle('gather-image', async (request) => {
    try {
      const url = new URL(request.url)
      const filePath = url.searchParams.get('path') ?? ''
      if (!filePath || !photoRepo.containsFilepath(filePath)) {
        return new Response('Not found', { status: 404 })
      }
      const requestedSize = Number(url.searchParams.get('size'))
      const size = Number.isFinite(requestedSize) && requestedSize > 0
        ? Math.min(5120, Math.round(requestedSize))
        : 1024
      const result = url.hostname === 'preview'
        ? await imageService.getPreview(filePath, size)
        : await imageService.getThumbnail(filePath, size)
      return new Response(new Uint8Array(result.buffer), {
        status: 200,
        headers: {
          'Content-Type': 'image/jpeg',
          'Cache-Control': 'private, max-age=3600',
        },
      })
    } catch (error) {
      console.warn('Image protocol request failed', error)
      return new Response('Image decode failed', { status: 500 })
    }
  })
}

app.enableSandbox()

const runtime: RuntimeLifecycle = {}

app.whenReady().then(async () => {
  initContainer()

  const db = svc<Database>(DI_TOKENS.DB)
  runtime.database = db
  await runMigrations(db)

  registerImageProtocol()
  registerIpc()

  const settings = svc<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
  const databaseRuntime = normalizeDatabaseRuntimeSettings(
    settings.get('db_synchronous', 'full'),
    settings.getNumber('db_cache_size_mb', 64),
  )
  db.pragma(`synchronous = ${databaseRuntime.synchronous}`)
  db.pragma(`cache_size = ${-databaseRuntime.cacheSizeMb * 1000}`)

  Menu.setApplicationMenu(Menu.buildFromTemplate(appMenuTemplate))
  createWindow()
  const jobs = svc<JobService>(DI_TOKENS.JOB_SERVICE)
  const indexer = svc<IndexService>(DI_TOKENS.INDEX_SERVICE)
  const metadataSync = svc<MetadataSyncCoordinator>(DI_TOKENS.METADATA_SYNC_COORDINATOR)
  runtime.jobs = jobs
  runtime.indexer = indexer
  runtime.metadataSync = metadataSync
  runtime.writerRouter = svc<MetadataWriterRouter>(DI_TOKENS.WRITER_ROUTER)
  jobs.start()
  jobs.setProgressSink((job, update) => {
    if (!mainWindow) return
    mainWindow.webContents.send('gather:event', 'jobs:progress', {
      jobId: job.id,
      jobType: job.type,
      scopeType: job.scopeType,
      scopeId: job.scopeId,
      current: update.current ?? 0,
      total: update.total ?? 0,
      message: update.message ?? '',
    })
  })
  indexer.startWatchers()
  metadataSync.start(
    (summary) => mainWindow?.webContents.send(
      'gather:event',
      'culling:sync-status',
      summary,
    ),
  )

  if (!app.isDefaultProtocolClient('gather')) {
    app.setAsDefaultProtocolClient('gather')
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
}).catch((error) => {
  const message = error instanceof Error ? error.message : String(error)
  console.error('Application startup failed:', message)
  if (process.env.GATHER_TEST_FAIL_MIGRATION !== 'after-migrate') {
    dialog.showErrorBox(
      'Gather 无法启动',
      `数据库迁移或应用初始化失败。原数据库已保留，请查看日志。\n\n${message}`,
    )
  }
  app.quit()
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

let quitting = false

function shutdown(): void {
  shutdownRuntime(runtime)
    .catch((err) => {
      console.error('Shutdown error:', err instanceof Error ? err.message : err)
    })
    .finally(async () => {
      // Flush debounced cache metadata so lastAccess/accessCount changes in
      // the debounce window survive the quit.
      try {
        await svc<ThumbnailCache>(DI_TOKENS.THUMBNAIL_CACHE).flush()
      } catch (err) {
        console.error('Thumbnail cache flush error:', err instanceof Error ? err.message : err)
      }
      app.quit()
    })
}

app.on('before-quit', (event) => {
  if (quitting) return
  event.preventDefault()
  quitting = true
  shutdown()
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
