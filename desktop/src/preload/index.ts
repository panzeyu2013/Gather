// desktop/src/preload/index.ts
// contextBridge 安全 API — 渲染进程唯一入口

import { contextBridge, ipcRenderer } from 'electron'

const ALLOWED_COMMANDS = new Set([
  'session.create', 'session.delete', 'session.delete_many', 'session.list', 'session.get', 'session.update', 'session.add_photos',
  'fkw.analyze', 'fkw.cancel_analysis', 'fkw.clusters', 'fkw.bind', 'fkw.unbind', 'fkw.merge',
  'fkw.remove_member', 'fkw.preview', 'fkw.writeback', 'fkw.confirm_sync', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.analyze', 'sim.cancel_analysis', 'sim.result', 'sim.recluster', 'sim.preview_writeback', 'sim.writeback',
  'sim.retry_failed_writeback', 'sim.writeback_items',
  'thumbnail.get', 'image.get_preview', 'image.get_thumbnail', 'image.prioritize_thumbnail', 'image.preload_thumbnails', 'image.get_dimensions',
  'photo.list',
  'settings.get_all', 'settings.get', 'settings.set', 'settings.reset',
])

const DESTRUCTIVE_COMMANDS = new Set([
  'session.delete', 'session.delete_many',
  'fkw.writeback', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.writeback', 'sim.retry_failed_writeback',
])

const ALLOWED_EVENTS = new Set([
  'progress',
  'engine:status',
  'c1:import-trigger',
  'c1:plugin-import',
])

function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)
  )
}

export interface GatherAPI {
  readonly sendCommand: (cmd: string, params?: Record<string, unknown>) => Promise<unknown>
  readonly onEvent: (event: string, callback: (data: unknown) => void) => () => void
  readonly onReady: (callback: () => void) => () => void
  readonly onPluginImport: (callback: (files: string[]) => void) => () => void
  readonly getSelectedPhotos: () => Promise<string[]>
  readonly reloadMetadata: () => Promise<void>
  readonly selectDirectory: () => Promise<string | null>
  readonly selectFiles: () => Promise<string[]>
  readonly scanDirectory: (dirPath: string) => Promise<string[]>
  readonly getVersion: () => Promise<string>
}

const api: GatherAPI = {
  sendCommand: (cmd, params = {}) => {
    if (!ALLOWED_COMMANDS.has(cmd)) {
      throw new Error(`Unknown command: ${cmd}`)
    }
    if (!isRecord(params)) {
      throw new Error('Command parameters must be an object')
    }
    if (DESTRUCTIVE_COMMANDS.has(cmd) && !params.confirmed) {
      throw new Error(`Destructive command '${cmd}' requires explicit confirmation`)
    }
    return ipcRenderer.invoke('gather:command', cmd, params)
  },

  onEvent: (event, callback) => {
    if (!ALLOWED_EVENTS.has(event)) {
      throw new Error(`Unknown event: ${event}`)
    }
    if (typeof callback !== 'function') {
      throw new Error('Event callback must be a function')
    }
    const handler = (_e: Electron.IpcRendererEvent, evt: string, data: unknown) => {
      if (evt === event) callback(data)
    }
    ipcRenderer.on('gather:event', handler)
    return () => {
      ipcRenderer.removeListener('gather:event', handler)
    }
  },

  onReady: (callback) => {
    if (typeof callback !== 'function') {
      throw new Error('Ready callback must be a function')
    }
    const handler = (_e: Electron.IpcRendererEvent, evt: string, data: unknown) => {
      if (evt === 'engine:status' && (data as { status: string }).status === 'ready') {
        callback()
        ipcRenderer.removeListener('gather:event', handler)
      }
    }
    ipcRenderer.on('gather:event', handler)
    return () => {
      ipcRenderer.removeListener('gather:event', handler)
    }
  },

  onPluginImport: (callback) => {
    if (typeof callback !== 'function') {
      throw new Error('Plugin import callback must be a function')
    }
    const handler = (_e: Electron.IpcRendererEvent, evt: string, data: unknown) => {
      if (evt === 'c1:plugin-import') {
        callback((data as { files: string[] }).files)
      }
    }
    ipcRenderer.on('gather:event', handler)
    return () => {
      ipcRenderer.removeListener('gather:event', handler)
    }
  },

  getSelectedPhotos: () =>
    ipcRenderer.invoke('c1:get-selected-photos'),

  reloadMetadata: () =>
    ipcRenderer.invoke('c1:reload-metadata'),

  selectDirectory: () =>
    ipcRenderer.invoke('app:select-directory'),

  selectFiles: () =>
    ipcRenderer.invoke('app:select-files'),

  scanDirectory: (dirPath) =>
    ipcRenderer.invoke('app:scan-directory', dirPath),

  getVersion: () =>
    ipcRenderer.invoke('app:version'),
}

contextBridge.exposeInMainWorld('gather', api)
