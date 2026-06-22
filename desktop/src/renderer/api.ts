// src/renderer/api.ts
// Engine API 客户端 — 零 HTTP，contextBridge 直连 Python

import type { SessionData, ProgressEvent, WritebackOptions } from '@gather/shared'
import { isRecord } from '@gather/shared'
import { toast } from './components/toast'

interface SessionCreateResult {
  id: string
}

function assertRecordResponse(value: unknown, context: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new Error(`${context} returned an invalid response.`)
  }
  return value
}

function isSessionData(value: unknown): value is SessionData {
  return isRecord(value)
    && typeof value.id === 'string'
    && typeof value.name === 'string'
    && typeof value.status === 'string'
    && typeof value.event_date === 'string'
    && typeof value.analysis_status === 'string'
    && typeof value.writeback_status === 'string'
    && typeof value.created_at === 'string'
    && typeof value.updated_at === 'string'
    && (value.photo_count === undefined || typeof value.photo_count === 'number')
}

export function formatError(err: unknown): string {
  if (err instanceof Error) {
    return err.message
  }
  if (typeof err === 'object' && err !== null) {
    const e = err as Record<string, unknown>
    if (e.message) {
      return String(e.message)
    }
    if (e.type) {
      return String(e.type)
    }
    try {
      return JSON.stringify(err)
    } catch {
      // fall through
    }
  }
  return String(err || 'Unknown error')
}

export function showError(err: unknown, fallback: string = 'An unexpected error occurred.'): void {
  const raw = formatError(err)
  if (!raw || raw === 'Unknown error') { toast(fallback, 'error'); return }
  const m = raw.toLowerCase()
  if (m.includes('keyerror') || m.includes('attributeerror')) {
    toast('An unexpected data error occurred. If the issue persists, please report it.', 'error')
  } else if (m.includes('valueerror') || m.includes('invalid')) {
    toast(raw, 'warning')
  } else if (m.includes('filenotfounderror') || m.includes('no such file')) {
    toast('A required file could not be found. Please check your photo directory.', 'error')
  } else if (m.includes('timed out') || m.includes('timeout')) {
    toast('The operation timed out. If analyzing, try with fewer photos. Otherwise, restart the app.', 'error')
  } else if (m.includes('connection lost') || m.includes('econnrefused')) {
    toast('Connection to the engine was lost. Please restart the app.', 'error')
  } else if (m.includes('modulenotfounderror') || m.includes('importerror')) {
    toast('A required application component is missing. Please reinstall the application.', 'error')
  } else if (m.includes('permission') || m.includes('eacces')) {
    toast('Permission denied. Check file permissions for the photo directory.', 'error')
  } else if (m.includes('python engine exited')) {
    toast('The processing engine has stopped unexpectedly. The application will attempt to restart.', 'error')
  } else if (m.includes('buffer overflow')) {
    toast('A data overflow occurred. Please try again with fewer photos.', 'error')
  } else {
    console.error('API error:', raw)
    toast(fallback, 'error')
  }
}

function send<T>(cmd: string, params: Record<string, unknown> = {}): Promise<T> {
  return window.gather.sendCommand(cmd, params) as Promise<T>
}

export const engine = {
  session: {
    create: (name: string) => send<unknown>('session.create', { name }).then(r => {
      const result = assertRecordResponse(r, 'session.create')
      if (typeof result.id !== 'string') throw new Error('session.create returned an invalid session id.')
      return result as unknown as SessionCreateResult
    }),
    delete: (id: string) => send('session.delete', { session_id: id, confirmed: true }),
    list: () => send<Record<string, unknown>>('session.list').then(r => {
      if (!Array.isArray(r.sessions)) {
        throw new Error('session.list returned an invalid sessions payload.')
      }
      if (!r.sessions.every(isSessionData)) {
        throw new Error('session.list returned malformed session data.')
      }
      return r.sessions as SessionData[]
    }),
    addPhotos: (id: string, paths: string[]) => send('session.add_photos', { session_id: id, filepaths: paths }),
    get: (id: string) => send<SessionData>('session.get', { session_id: id }).then(r => {
      if (!isSessionData(r)) {
        throw new Error('session.get returned malformed session data.')
      }
      return r as SessionData
    }),
    update: (id: string, params: { name: string }) => send<SessionData>('session.update', { session_id: id, ...params }),
  },
  fkw: {
    analyze:       (id: string, opts?: { eps?: number; min_samples?: number }) => send('fkw.analyze', { session_id: id, ...opts }),
    cancelAnalysis:(id: string) => send('fkw.cancel_analysis', { session_id: id }),
    getClusters:   (id: string) => send<Record<string, unknown>>('fkw.clusters', { session_id: id }),
    bind:          (id: string, cid: number, role: string, kw: string[]) => send('fkw.bind', { session_id: id, cluster_id: cid, role, keywords: kw }),
    unbind:        (id: string, cid: number) => send('fkw.unbind', { session_id: id, cluster_id: cid }),
    merge:         (id: string, src: number, tgt: number) => send('fkw.merge', { session_id: id, source: src, target: tgt }),
    removeMember:  (id: string, cid: number, pid: string) => send('fkw.remove_member', { session_id: id, cluster_id: cid, photo_id: pid }),
    preview:       (id: string) => send<Record<string, unknown>>('fkw.preview', { session_id: id }),
    writeback:     (id: string) => send<Record<string, unknown>>('fkw.writeback', { session_id: id, confirmed: true }),
    confirmSync:   (id: string) => send<Record<string, unknown>>('fkw.confirm_sync', { session_id: id }),
    cleanup:       (id: string) => send<Record<string, unknown>>('fkw.cleanup', { session_id: id, confirmed: true }),
    confirmCleanup: (id: string) => send<Record<string, unknown>>('fkw.confirm_cleanup', { session_id: id, confirmed: true }),
  },
  sim: {
    analyze:    (id: string, opts?: { threshold?: number; min_group_size?: number }) => send('sim.analyze', { session_id: id, ...opts }),
    cancelAnalysis:(id: string) => send('sim.cancel_analysis', { session_id: id }),
    getResult:  (id: string) => send<Record<string, unknown>>('sim.result', { session_id: id }),
    recluster:  (id: string, threshold: number, minGroup: number) => send<Record<string, unknown>>('sim.recluster', { session_id: id, threshold, min_group_size: minGroup }),
    previewWriteback: (id: string, groupIds: Array<number | string>, options: WritebackOptions) => send<Record<string, unknown>>('sim.preview_writeback', { session_id: id, group_ids: groupIds, options }),
    writeback:  (id: string, groupIds: Array<number | string>, options: WritebackOptions) => send<Record<string, unknown>>('sim.writeback', { session_id: id, group_ids: groupIds, options, confirmed: true }),
  },
  // TODO: validate response shape at runtime
  onProgress: (cb: (d: ProgressEvent['data']) => void): (() => void) =>
    window.gather.onEvent('progress', cb as (d: unknown) => void),
}

export const c1 = {
  getSelectedPhotos: () => window.gather.getSelectedPhotos(),
  reloadMetadata: () => window.gather.reloadMetadata(),
}

export const app = {
  selectDirectory: () => window.gather.selectDirectory(),
  selectFiles: () => window.gather.selectFiles(),
  getVersion: () => window.gather.getVersion(),
}
