// desktop/src/preload/index.ts
// contextBridge 安全 API — 渲染进程唯一入口

import { contextBridge, ipcRenderer } from 'electron'
import { ALLOWED_COMMANDS, ALLOWED_EVENTS, DESTRUCTIVE_COMMANDS, isRecord } from '@gather/shared'

export interface GatherAPI {
  readonly sendCommand: (cmd: string, params?: Record<string, unknown>) => Promise<unknown>
  readonly onEvent: (event: string, callback: (data: unknown) => void) => () => void
  readonly onReady: (callback: () => void) => () => void
  readonly getSelectedPhotos: () => Promise<string[]>
  readonly reloadMetadata: () => Promise<void>
  readonly selectDirectory: () => Promise<string | null>
  readonly selectFiles: () => Promise<string[]>
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
    return ipcRenderer.invoke('python:command', cmd, params)
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
    ipcRenderer.on('python:event', handler)
    return () => {
      ipcRenderer.removeListener('python:event', handler)
    }
  },

  onReady: (callback) => {
    if (typeof callback !== 'function') {
      throw new Error('Ready callback must be a function')
    }
    const handler = () => callback()
    ipcRenderer.on('python:ready', handler)
    return () => {
      ipcRenderer.removeListener('python:ready', handler)
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
}

contextBridge.exposeInMainWorld('gather', api)
