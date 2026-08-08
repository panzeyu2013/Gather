// packages/shared/src/protocol/session.ts
import type { SessionStatus, AnalysisStatus, WritebackStatus } from './core'

export interface SessionCreateParams {
  name: string
  filepaths?: string[]
  source?: string
  sourcePath?: string
  /** Set when the initial directory scan hit its file bound; the remaining
   * photos are expected to be filled in by background indexing. */
  truncatedImport?: boolean
}

/** One-hop local-directory import: the payload carries only the source path,
 * never a file-path array. The main process creates the session row and
 * enqueues the `metadata.scan` index job, which streams the walk in-process. */
export interface SessionCreateFromDirectoryParams {
  name?: string
  sourcePath: string
}

export interface SessionDeleteParams {
  sessionId: string
  confirmed: boolean
}

export interface SessionDeleteManyParams {
  sessionIds: string[]
  confirmed: boolean
}

export interface SessionAddPhotosParams {
  sessionId: string
  filepaths: string[]
  source?: string
}

export interface SessionGetParams {
  sessionId: string
}

export interface SessionUpdateParams {
  sessionId: string
  name: string
}

export interface SessionData {
  id: string
  name: string
  status: SessionStatus
  photoCount: number
  analysisStatus: AnalysisStatus
  writebackStatus: WritebackStatus
  importSource: string
  sourcePath: string
  failedWritebackCount: number
  truncatedImport: boolean
  createdAt: string
  updatedAt: string
}

export interface PhotoData {
  id: string
  sessionId: string
  filepath: string
  filename: string
  checksum: string
  hasExistingXmp: boolean
  faceCount: number
  width: number
  height: number
  metadata: Record<string, unknown>
  result: Record<string, unknown>
  status: string
  assetId?: string
  variantCount?: number
  variants?: Array<{
    photoId: string
    filepath: string
    filename: string
    role: string
  }>
  createdAt: string
  updatedAt: string
}
