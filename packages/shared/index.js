// Runtime JS entry point for @gather/shared.
// TypeScript types are resolved via package.json "types": "./src/index.ts".
// This file provides runtime-compatible CommonJS exports for the Electron main process.

// ── Status enums ──
const AnalysisStatus = Object.freeze({
  IDLE: 'idle',
  RUNNING: 'running',
  DONE: 'done',
  FAILED: 'failed',
  CANCELLED: 'cancelled',
})

const SessionStatus = Object.freeze({
  DRAFT: 'draft',
  PHOTOS_LOADED: 'photos_loaded',
  ANALYZING: 'analyzing',
  REVIEW: 'review',
  COMPLETED: 'completed',
})

const WritebackStatus = Object.freeze({
  IDLE: 'idle',
  RUNNING: 'running',
  DONE: 'done',
  PARTIAL: 'partial',
  CLEANED: 'cleaned',
})

// ── Command / event allowlists ──
const ALLOWED_COMMANDS = new Set([
  'session.create', 'session.delete', 'session.list', 'session.get', 'session.update', 'session.add_photos',
  'fkw.analyze', 'fkw.cancel_analysis', 'fkw.clusters', 'fkw.bind', 'fkw.unbind', 'fkw.merge',
  'fkw.remove_member', 'fkw.preview', 'fkw.writeback', 'fkw.confirm_cleanup',
  'sim.analyze', 'sim.cancel_analysis', 'sim.result', 'sim.recluster', 'sim.writeback',
  'thumbnail.get', 'shutdown',
])

const DESTRUCTIVE_COMMANDS = new Set([
  'session.delete',
  'fkw.writeback', 'fkw.confirm_cleanup',
  'sim.writeback',
])

const ALLOWED_EVENTS = new Set([
  'progress',
  'python:ready',
  'c1:import-trigger',
  'python:disconnected',
])

function isRecord(value) {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)
  )
}

// ── Polling / timing constants ──
const MAX_POLL_RETRIES_SIM = 300
const MAX_POLL_RETRIES_FKW = 240
const POLL_INTERVAL_SIM = 1000
const POLL_INTERVAL_FKW = 3000

const TOAST_DURATION_LONG = 12000
const TOAST_DURATION_SHORT = 5000
const TOAST_DURATION_ERROR = 8000

const SIM_DEBOUNCE_MS = 300
const ENGINE_TIMEOUT_MS = 60000
const ANALYSIS_COMPLETION_FALLBACK_MS = 300000
const MAX_FACE_DETECTION_PHOTOS = 5000

module.exports = {
  AnalysisStatus,
  SessionStatus,
  WritebackStatus,
  ALLOWED_COMMANDS,
  DESTRUCTIVE_COMMANDS,
  ALLOWED_EVENTS,
  isRecord,
  MAX_POLL_RETRIES_SIM,
  MAX_POLL_RETRIES_FKW,
  POLL_INTERVAL_SIM,
  POLL_INTERVAL_FKW,
  TOAST_DURATION_LONG,
  TOAST_DURATION_SHORT,
  TOAST_DURATION_ERROR,
  SIM_DEBOUNCE_MS,
  ENGINE_TIMEOUT_MS,
  ANALYSIS_COMPLETION_FALLBACK_MS,
  MAX_FACE_DETECTION_PHOTOS,
}
