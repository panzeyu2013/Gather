// src/main/capture-one.ts
// Capture One 集成 — osascript 桥接

import { execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import { getService } from './di/init'
import { DI_TOKENS } from './di/container'
import type { SettingsService } from './services/settings/settings.service'
import type { SessionRepository } from './db/repositories/session.repo'
import type { GatherErrorCode } from '@gather/shared'
import { classifyCaptureOneError } from './services/capture-one/errors'

const execFile = promisify(execFileCb)

// Error codes thrown across IPC (design_improvements.md 4.4.2): the main
// process owns no natural-language copy, the renderer maps the code.
// TCC Automation denial surfaces as Apple Events error -1743 / "not
// authorized"; no open document produces "No document is open" variants;
// a hang produces "timed out" / -1712. Classification lives in one shared
// module (services/capture-one/errors.ts) so the bridge and the health
// probe cannot drift apart.
function classifyCaptureOneErrorCode(raw: string): GatherErrorCode {
  switch (classifyCaptureOneError(raw)) {
    case 'denied':
      return 'C1_NOT_AUTHORIZED'
    case 'noDocument':
      return 'C1_NO_DOCUMENT'
    default:
      return 'C1_SCRIPT_FAILED'
  }
}

function throwCode(code: GatherErrorCode, cause?: unknown): never {
  const error = new Error(code, cause === undefined ? undefined : { cause })
  throw error
}

// Allow legitimate Capture One install names such as "Capture One Pro",
// "Capture One Express" or "Capture One 16 Pro" while keeping the name safe
// to embed into an osascript `tell application "…"` string. The source is the
// local process list, so this only guards against stray/hostile process names.
export function sanitizeCaptureOneAppName(name: string): string | null {
  const trimmed = name.trim()
  if (!/^Capture One( [A-Za-z0-9 ._+()$-]*)?$/i.test(trimmed)) return null
  return trimmed
}

export function buildReloadMetadataScript(appName: string): string {
  return `
tell application "${appName}"
  reload metadata of current document
end tell
`
}

export function buildSelectedVariantsScript(appName: string): string {
  return `
tell application "${appName}"
  try
    set output to ""
    set selectedImages to selected variants of current document
    repeat with img in selectedImages
      set output to output & (path of img as text) & linefeed
    end repeat
    return output
  on error
    return ""
  end try
end tell
`
}

function getSettings(): SettingsService {
  return getService<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
}

function getSessionRepo(): SessionRepository {
  return getService<SessionRepository>(DI_TOKENS.SESSION_REPO)
}

async function execAppleScript(script: string, retries?: number): Promise<string> {
  const settings = getSettings()
  const maxRetries = retries ?? settings.getNumber('c1_retries', 3)
  const timeout = settings.getNumber('c1_timeout_ms', 15000)
  for (let i = 0; i < maxRetries; i++) {
    try {
      const { stdout } = await execFile('osascript', ['-e', script], { timeout })
      return stdout
    } catch (err) {
      if (i === maxRetries - 1) throw err
      await new Promise(r => setTimeout(r, 500 * (i + 1)))
    }
  }
  // Only reachable with a non-positive retry setting; never let raw text leak.
  throwCode('C1_SCRIPT_FAILED')
}

async function getCaptureOneAppName(): Promise<string | null> {
  let names: string[]
  try {
    const { stdout } = await execFile('osascript', [
      '-e', 'tell application "System Events" to get name of every process whose name contains "Capture One"'
    ])
    names = stdout.trim().split(/,\s*/).filter(Boolean)
  } catch {
    return null
  }
  const appName = names.length > 0 ? names[0] : null
  if (!appName) return null
  const sanitized = sanitizeCaptureOneAppName(appName)
  if (!sanitized) {
    // The raw name is logged main-side only; the renderer gets a code.
    console.error('Potentially unsafe process name rejected:', appName)
    throwCode('C1_SCRIPT_FAILED')
  }
  return sanitized
}

/** 获取 Capture One 当前选中的照片路径列表 */
export async function getSelectedPhotos(): Promise<string[]> {
  const appName = await getCaptureOneAppName()
  if (!appName) {
    throwCode('C1_NOT_RUNNING')
  }

  const script = buildSelectedVariantsScript(appName)
  try {
    const stdout = await execAppleScript(script)
    return stdout.trim().split('\n').map(s => s.trim()).filter(Boolean)
  } catch (err) {
    console.error('capture-one getSelectedPhotos failed:', err)
    throwCode(classifyCaptureOneErrorCode(err instanceof Error ? err.message : String(err)), err)
  }
}

/**
 * 向 Capture One 发送 "重新加载元数据" 指令。
 * sessionId 可选：提供时仅在成功（含延迟窗口）后写入 reload_acked_at，
 * 作为 safeToCleanup 重启重推导的持久标记。缺失时不触碰数据库。
 */
export async function reloadMetadata(sessionId?: string): Promise<void> {
  const appName = await getCaptureOneAppName()
  if (!appName) {
    throwCode('C1_NOT_RUNNING')
  }

  // Do not swallow AppleScript errors here. The renderer only offers the
  // confirm/cleanup steps after this promise resolves, so a false success can
  // cause Gather to restore XMP that Capture One never loaded.
  const script = buildReloadMetadataScript(appName)
  try {
    await execAppleScript(script)
    await new Promise(r => setTimeout(r, getSettings().getNumber('c1_reload_delay_ms', 500)))
  } catch (err) {
    console.error('capture-one reloadMetadata failed:', err)
    throwCode(classifyCaptureOneErrorCode(err instanceof Error ? err.message : String(err)), err)
  }
  if (typeof sessionId === 'string' && sessionId.length > 0) {
    getSessionRepo().setReloadAckedAt(sessionId, new Date().toISOString())
  }
}
