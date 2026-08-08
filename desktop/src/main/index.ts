import { app, BrowserWindow, ipcMain, dialog, protocol, session, shell } from 'electron'
import { join, resolve } from 'path'
import { getSelectedPhotos, reloadMetadata } from './capture-one'
import { c1Health } from './services/capture-one/c1-health'
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
import { CaptureOneSyncState } from './services/capture-one/sync-state'
import { IMAGE_CONFIG } from './services/image/image-config'

import { CommandRegistry, registerAllIpcHandlers } from './ipc/registry'
import { setupAppMenu } from './menu'
import { resolveEffectiveLocale } from './locale'
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
import { registerWorkspaceHandlers } from './ipc/workspace.ipc'
import { WorkspaceStatusService } from './services/workspace/workspace-status.service'
import { QualityService } from './services/quality/quality.service'
import { NavigationService } from './services/navigation/navigation.service'
import { parseImportDeepLink } from './deep-link'
import { normalizeDatabaseRuntimeSettings } from './runtime-settings'
import { scanDirectory } from './utils/scan-directory'

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
  registerSessionHandlers(registry, sessionService, svc<JobService>(DI_TOKENS.JOB_SERVICE))
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
  registerWorkspaceHandlers(
    registry,
    svc<WorkspaceStatusService>(DI_TOKENS.WORKSPACE_STATUS_SERVICE),
  )

  ipcMain.handle('c1:get-selected-photos', async (e) => {
    ensureMainWindowSender(e)
    return getSelectedPhotos()
  })

  ipcMain.handle('c1:reload-metadata', async (e, sessionId?: string) => {
    ensureMainWindowSender(e)
    const normalized = typeof sessionId === 'string' && sessionId.length > 0 && sessionId.length <= 256
      ? sessionId
      : undefined
    await reloadMetadata(normalized)
    // reload_acked_at 已持久化（capture-one.ts）：协调器不会因 ack 发事件，
    // 这里主动重推导一次，保持 ack 转换可观测（2.5 P1）。
    if (normalized) svc<CaptureOneSyncState>(DI_TOKENS.CAPTURE_ONE_SYNC_STATE).observeReloadAck(normalized)
  })

  ipcMain.handle('c1:health', async (e) => {
    ensureMainWindowSender(e)
    return c1Health()
  })

  // 渲染层同步面板的会话级状态机视图（2.3.5）：派生状态 + 行计数 + ack。
  // 只读聚合，不触发任何动作；与 CaptureOneSyncState 的重推导共用同一真相源。
  ipcMain.handle('c1:sync-state', async (e, sessionId: string) => {
    ensureMainWindowSender(e)
    if (
      typeof sessionId !== 'string' ||
      sessionId.length === 0 ||
      sessionId.length > 256
    ) {
      throw new Error('Invalid session id')
    }
    const syncState = svc<CaptureOneSyncState>(DI_TOKENS.CAPTURE_ONE_SYNC_STATE)
    const summary = metadataSync.getSummary(sessionId)
    const view = syncState.getSessionView(sessionId)
    return {
      state: view.state,
      reloadAckedAt: view.reloadAckedAt,
      xmp: {
        pending: summary.pending,
        writing: summary.writing,
        written: summary.written,
        failed: summary.failed,
        conflict: summary.conflict,
        synced: summary.synced,
      },
    }
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

  // Effective UI locale for the renderer bootstrap (i18n P2 收尾): same
  // resolution chain as the menu (settings override > --lang > system > en).
  // The renderer must apply it via initI18n() before first render to avoid a
  // locale flash.
  ipcMain.handle('app:get-app-locale', (e) => {
    ensureMainWindowSender(e)
    return {
      language: resolveEffectiveLocale(
        app.commandLine.getSwitchValue('lang'),
        app.getLocale(),
        settingsService.get('ui_language', ''),
      ),
    }
  })

  // Dialog copy is owned by the renderer (design_improvements.md 4.4.2):
  // the caller passes a translated title/filter name, the main process only
  // shows the OS dialog. Missing title falls back to the OS default.
  ipcMain.handle('app:select-directory', async (e, title?: string) => {
    ensureMainWindowSender(e)
    if (!mainWindow) throw new Error('No window')
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory'],
      title: typeof title === 'string' && title.length > 0 ? title : undefined,
    })
    return result.canceled ? null : result.filePaths[0]
  })

  ipcMain.handle('app:select-files', async (e, options?: { title?: string; filterName?: string }) => {
    ensureMainWindowSender(e)
    if (!mainWindow) throw new Error('No window')
    const opts = options && typeof options === 'object' ? options : {}
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openFile', 'multiSelections'],
      title: typeof opts.title === 'string' && opts.title.length > 0 ? opts.title : undefined,
      filters: [
        {
          name: typeof opts.filterName === 'string' && opts.filterName.length > 0
            ? opts.filterName
            : undefined,
          extensions: supportedImageExtensions.map((extension) => extension.slice(1)),
        },
      ].filter((filter): filter is { name: string; extensions: string[] } => Boolean(filter.name)),
    })
    return result.canceled ? [] : result.filePaths
  })

  ipcMain.handle('app:scan-directory', async (e, dirPath: string) => {
    ensureMainWindowSender(e)
    if (!mainWindow) throw new Error('No window')
    if (typeof dirPath !== 'string' || dirPath.length === 0) {
      throw new Error('Invalid directory path')
    }
    return scanDirectory(dirPath, { supportedExtensions: supportedImageExtensionSet })
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
    settings.get('db_synchronous', 'normal'),
    settings.getNumber('db_cache_size_mb', 64),
  )
  db.pragma(`synchronous = ${databaseRuntime.synchronous}`)
  db.pragma(`cache_size = ${-databaseRuntime.cacheSizeMb * 1000}`)

  // Effective locale: settings `ui_language` override > --lang switch >
  // app.getLocale() (design_improvements.md 4.2, see main/locale.ts). The
  // renderer mirrors this via `app:get-app-locale` at bootstrap.
  setupAppMenu(
    resolveEffectiveLocale(
      app.commandLine.getSwitchValue('lang'),
      app.getLocale(),
      settings.get('ui_language', ''),
    ),
    (eventName, payload) => mainWindow?.webContents.send('gather:event', eventName, payload),
  )
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
      phase: update.phase,
      message: update.message ?? '',
      // Terminal frames (emitTerminal) carry the final status so clients can
      // clear the "analyzing" state; regular frames omit it. interrupted is
      // terminal too (shutdown interrupted the run; a reloaded page relies on
      // this frame to stop showing "analyzing").
      status: ['succeeded', 'failed', 'cancelled', 'interrupted'].includes(job.status)
        ? job.status
        : undefined,
    })
  })
  indexer.startWatchers()
  metadataSync.start(
    (summary) => {
      mainWindow?.webContents.send(
        'gather:event',
        'culling:sync-status',
        summary,
      )
      // P1 事件接线（2.5）：协调器每次 emitSummary 后重推导会话状态，
      // 转换以 [capture-one-sync] 日志输出（验收：状态机转换全部可观测）。
      // 仅观测，不触发自动 reload / cleanup（保守策略不变）。
      svc<CaptureOneSyncState>(DI_TOKENS.CAPTURE_ONE_SYNC_STATE).observeSummary(summary)
    },
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
    // Startup-fatal dialog: no renderer exists to map error copy, so the
    // title/body are resolved with the same effective-locale chain as the
    // menu (settings `ui_language` override > --lang switch > app locale).
    // The settings service lives behind DI, which may have failed here, so
    // the persisted override is read directly from the settings table
    // (best-effort; a read failure just falls back to the --lang/system chain).
    let uiLanguage = ''
    try {
      const row = new Database()
        .prepare('SELECT value FROM app_settings WHERE key = ?')
        .get('ui_language') as { value?: string } | undefined
      uiLanguage = typeof row?.value === 'string' ? row.value : ''
    } catch {
      // Best-effort: the DB may be unreachable when initialization failed.
    }
    const isZh = resolveEffectiveLocale(
      app.commandLine.getSwitchValue('lang'),
      app.getLocale(),
      uiLanguage,
    ) === 'zh-CN'
    dialog.showErrorBox(
      isZh ? 'Gather 无法启动' : 'Gather failed to start',
      isZh
        ? `数据库迁移或应用初始化失败。原数据库已保留，请查看日志。\n\n${message}`
        : `Database migration or app initialization failed. The original database was kept; see the logs.\n\n${message}`,
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
