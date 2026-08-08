// src/main/services/capture-one/c1-health.ts
// Capture One 连接预检 — 一次完成四层检查（设计文档 2.3.4）

import { execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import {
  buildSelectedVariantsScript,
  sanitizeCaptureOneAppName,
} from '../../capture-one'
import {
  isAutomationDeniedMessage,
  isTimeoutMessage,
} from './errors'

export { isAutomationDeniedMessage, isTimeoutMessage } from './errors'

const execFile = promisify(execFileCb)

export interface C1Health {
  reachable: boolean
  appRunning: boolean
  appName: string | null
  documentOpen: boolean
  automationAuthorized: boolean
  selectedCount: number
  latencyMs: number
  lastError: string | null
  /** The probe timed out (Apple Events -1712 or the probe was killed). */
  timedOut: boolean
  timestamp: string
}

// Preflight probes are diagnostic, not user actions: keep them quick so the
// UI can refresh the capsule without a visible stall.
const PROBE_TIMEOUT_MS = 3000

// Same System Events process-list probe used by capture-one.ts; reusing the
// exact shape keeps the two code paths observing the same process facts.
const PROCESS_PROBE_SCRIPT =
  'tell application "System Events" to get name of every process whose name contains "Capture One"'

export function parseProcessNames(stdout: string): string[] {
  return stdout.trim().split(/,\s*/).filter(Boolean)
}

export function countVariantOutputLines(stdout: string): number {
  return stdout.trim().split('\n').map(line => line.trim()).filter(Boolean).length
}

function buildDocumentProbeScript(appName: string): string {
  return `tell application "${appName}"
  get name of current document
end tell`
}

interface ProbeResult {
  stdout: string
  latencyMs: number
  error: string | null
}

async function runProbe(script: string): Promise<ProbeResult> {
  const startedAt = Date.now()
  try {
    const { stdout } = await execFile('osascript', ['-e', script], {
      timeout: PROBE_TIMEOUT_MS,
    })
    return { stdout, latencyMs: Date.now() - startedAt, error: null }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return { stdout: '', latencyMs: Date.now() - startedAt, error: message }
  }
}

/** 一次完成四层预检（2.3.4），失败即回退：不抛异常，逐层降级并保留诊断信息。 */
export async function c1Health(): Promise<C1Health> {
  const health: C1Health = {
    reachable: false,
    appRunning: false,
    appName: null,
    documentOpen: false,
    automationAuthorized: false,
    selectedCount: 0,
    latencyMs: 0,
    lastError: null,
    timedOut: false,
    timestamp: new Date().toISOString(),
  }

  const reachableProbe = await runProbe(PROCESS_PROBE_SCRIPT)
  health.latencyMs = reachableProbe.latencyMs
  if (reachableProbe.error) {
    health.lastError = reachableProbe.error
    if (isTimeoutMessage(reachableProbe.error)) health.timedOut = true
    return health
  }
  health.reachable = true

  const names = parseProcessNames(reachableProbe.stdout)
  if (names.length === 0) return health
  health.appRunning = true

  const sanitized = sanitizeCaptureOneAppName(names[0])
  if (!sanitized) {
    health.lastError = `Unsafe Capture One process name rejected: ${names[0]}`
    return health
  }
  health.appName = sanitized

  const documentProbe = await runProbe(buildDocumentProbeScript(sanitized))
  health.latencyMs = documentProbe.latencyMs
  if (documentProbe.error) {
    health.lastError = documentProbe.error
    if (isTimeoutMessage(documentProbe.error)) {
      // The app hung (or a TCC prompt is pending): the automation channel is
      // not usable, so a timeout must never claim automationAuthorized.
      health.timedOut = true
      health.automationAuthorized = false
    } else if (isAutomationDeniedMessage(documentProbe.error)) {
      health.automationAuthorized = false
    } else {
      // The event reached the app (TCC already passed): the failure is the
      // missing current document or an app-side error, not a connectivity one.
      health.automationAuthorized = true
      health.documentOpen = false
    }
    return health
  }
  health.automationAuthorized = true
  health.documentOpen = true

  const selectionProbe = await runProbe(buildSelectedVariantsScript(sanitized))
  health.latencyMs = selectionProbe.latencyMs
  if (selectionProbe.error) {
    health.lastError = selectionProbe.error
    if (isTimeoutMessage(selectionProbe.error)) health.timedOut = true
  } else {
    health.selectedCount = countVariantOutputLines(selectionProbe.stdout)
  }
  return health
}
