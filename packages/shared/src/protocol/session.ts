// packages/shared/src/protocol/session.ts
import type { SessionStatus, AnalysisStatus, WritebackStatus } from './core'

export interface SessionCreateParams {
  name: string
  filepaths?: string[]
  source?: string
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
  failedWritebackCount: number
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
  metadata: Record<string, unknown>
  result: Record<string, unknown>
  status: string
  createdAt: string
  updatedAt: string
}
