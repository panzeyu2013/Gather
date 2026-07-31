// desktop/src/preload/index.ts
// contextBridge 安全 API — 渲染进程唯一入口

import { contextBridge, ipcRenderer } from 'electron'
import type { Command, Event } from '@gather/shared'

type CommandType = Command['type']
type EventType = Event['type']

// Sandboxed Electron preloads cannot require workspace packages at runtime.
// Keep these values inline and verify parity with the shared protocol in tests.
const ALLOWED_COMMANDS = new Set<CommandType>([
  'session.create', 'session.delete', 'session.delete_many', 'session.list', 'session.get', 'session.update', 'session.add_photos',
  'fkw.analyze', 'fkw.recluster', 'fkw.cancel_analysis', 'fkw.clusters', 'fkw.bind', 'fkw.unbind', 'fkw.merge',
  'fkw.remove_member', 'fkw.get_cluster_thumbnail', 'fkw.preview', 'fkw.writeback', 'fkw.confirm_sync', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.analyze', 'sim.cancel_analysis', 'sim.result', 'sim.recluster',
  'sim.preview_writeback', 'sim.writeback', 'sim.writeback_items', 'sim.retry_failed_writeback',
  'sim.confirm_sync', 'sim.cleanup',
  'image.prioritize_thumbnail', 'image.preload_thumbnails', 'image.preload_previews', 'image.get_dimensions',
  'photo.list',
  'settings.get_all', 'settings.get', 'settings.set', 'settings.reset', 'settings.get_ml_status',
  'person.list', 'person.get', 'person.create', 'person.update', 'person.delete', 'person.merge', 'person.remove_photo', 'person.search_photos',
  'metadata.get', 'metadata.set', 'metadata.batch_set', 'metadata.conflicts', 'metadata.resolve_conflict', 'metadata.orphans', 'metadata.resolve_orphan',
  'dup.scan', 'dup.groups', 'dup.resolve', 'dup.resolve_member',
  'filter.photos', 'filter.photos_global', 'filter.suggest',
  'album.create', 'album.list', 'album.get', 'album.update', 'album.delete', 'album.get_photos',
  'export.preview', 'export.execute', 'export.cancel', 'export.report',
  'template.create', 'template.list', 'template.get', 'template.update', 'template.delete', 'template.apply',
  'culling.groups', 'culling.decide', 'culling.batch_decide', 'culling.summary', 'culling.writeback',
  'culling.list', 'culling.update', 'culling.batch_update', 'culling.decide_group', 'culling.sync_status', 'culling.flush', 'culling.retry_sync', 'culling.finalize_sync',
  'culling.retry_failed_writeback', 'culling.confirm_sync', 'culling.cleanup', 'culling.reset', 'culling.history', 'culling.apply_history',
  'jobs.list', 'jobs.cancel', 'jobs.retry', 'jobs.clear_completed',
  'assets.candidates', 'assets.accept_candidate', 'assets.reject_candidate', 'assets.volumes', 'assets.relink_root',
  'index.scan',
  'quality.analyze', 'quality.get', 'navigation.analyze', 'navigation.list', 'navigation.split', 'navigation.merge',
])

const DESTRUCTIVE_COMMANDS = new Set<CommandType>([
  'session.delete', 'session.delete_many',
  'fkw.writeback', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.writeback', 'sim.retry_failed_writeback', 'sim.cleanup',
  'person.delete', 'person.merge', 'person.remove_photo',
  'dup.resolve', 'dup.resolve_member',
  'culling.writeback', 'culling.retry_failed_writeback', 'culling.cleanup', 'culling.reset',
  'culling.finalize_sync',
  'metadata.set', 'metadata.batch_set', 'metadata.resolve_conflict', 'metadata.resolve_orphan',
  'jobs.clear_completed', 'assets.accept_candidate', 'assets.reject_candidate', 'assets.relink_root',
  'template.delete', 'album.delete', 'export.execute', 'template.apply',
])

const ALLOWED_EVENTS = new Set<EventType>([
  'progress',
  'engine:status',
  'c1:import-trigger',
  'c1:plugin-import',
  'export:progress',
  'models:download-progress',
  'gather:notification',
  'culling:sync-status',
])

const LISTENER_COUNTS = new Map<string, number>()
const MAX_LISTENERS_PER_EVENT = 10

function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)
  )
}

export interface GatherAPI {
  readonly sendCommand: (cmd: CommandType, params?: Record<string, unknown>) => Promise<unknown>
  readonly onEvent: (event: EventType, callback: (data: unknown) => void) => () => void
  readonly onReady: (callback: () => void) => () => void
  readonly onPluginImport: (callback: (files: string[]) => void) => () => void
  readonly getSelectedPhotos: () => Promise<string[]>
  readonly reloadMetadata: () => Promise<void>
  readonly selectDirectory: () => Promise<string | null>
  readonly selectFiles: () => Promise<string[]>
  readonly getVersion: () => Promise<string>
  readonly openDirectory: (dirPath: string) => Promise<void>
  readonly scanDirectory: (dirPath: string) => Promise<string[]>
  readonly downloadDefaultModels: () => Promise<void>
  readonly onModelDownloadProgress: (callback: (data: unknown) => void) => () => void
}

const api: GatherAPI = {
  sendCommand: (cmd, params = {}) => {
    if (!ALLOWED_COMMANDS.has(cmd)) {
      throw new Error(`Unknown command: ${cmd}`)
    }
    if (!isRecord(params)) {
      throw new Error('Command parameters must be an object')
    }
    if (DESTRUCTIVE_COMMANDS.has(cmd) && params.confirmed !== true) {
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

    const current = (LISTENER_COUNTS.get(event) ?? 0) + 1
    LISTENER_COUNTS.set(event, current)

    if (current >= MAX_LISTENERS_PER_EVENT) {
      console.warn(
        `[EventSystem] "${event}" has ${current} listeners, possible leak. ` +
        `Active events: ${[...LISTENER_COUNTS.entries()].map(([k, v]) => `${k}:${v}`).join(', ')}`
      )
    }

    const handler = (_e: Electron.IpcRendererEvent, evt: string, data: unknown) => {
      if (evt === event) callback(data)
    }
    ipcRenderer.on('gather:event', handler)
    return () => {
      LISTENER_COUNTS.set(event, Math.max(0, (LISTENER_COUNTS.get(event) ?? 1) - 1))
      ipcRenderer.removeListener('gather:event', handler)
    }
  },

  onReady: (callback) => {
    if (!ALLOWED_EVENTS.has('engine:status')) {
      throw new Error('Event "engine:status" is not allowed')
    }
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
    if (!ALLOWED_EVENTS.has('c1:plugin-import')) {
      throw new Error('Event "c1:plugin-import" is not allowed')
    }
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

  getVersion: () =>
    ipcRenderer.invoke('app:version'),

  openDirectory: (dirPath) =>
    ipcRenderer.invoke('app:open-directory', dirPath),

  scanDirectory: (dirPath) =>
    ipcRenderer.invoke('app:scan-directory', dirPath),

  downloadDefaultModels: () =>
    ipcRenderer.invoke('models.download_default'),

  onModelDownloadProgress: (callback) => {
    if (!ALLOWED_EVENTS.has('models:download-progress')) {
      throw new Error('Event "models:download-progress" is not allowed')
    }
    if (typeof callback !== 'function') {
      throw new Error('Model download progress callback must be a function')
    }
    const handler = (_e: Electron.IpcRendererEvent, evt: string, data: unknown) => {
      if (evt === 'models:download-progress') {
        callback(data)
      }
    }
    ipcRenderer.on('gather:event', handler)
    return () => {
      ipcRenderer.removeListener('gather:event', handler)
    }
  },
}

contextBridge.exposeInMainWorld('gather', api)
