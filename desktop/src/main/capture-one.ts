// src/main/capture-one.ts
// Capture One 集成 — osascript 桥接

import { execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import { getService } from './di/init'
import { DI_TOKENS } from './di/container'
import type { SettingsService } from './services/settings/settings.service'

const execFile = promisify(execFileCb)

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

function getSettings(): SettingsService {
  return getService<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
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
  throw new Error('unreachable')
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
    throw new Error(`Potentially unsafe process name rejected: ${appName}`)
  }
  return sanitized
}

/** 获取 Capture One 当前选中的照片路径列表 */
export async function getSelectedPhotos(): Promise<string[]> {
  const appName = await getCaptureOneAppName()
  if (!appName) {
    throw new Error('Could not connect to Capture One. Please make sure Capture One is running with a document open.')
  }

  const script = `
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
  try {
    const stdout = await execAppleScript(script)
    return stdout.trim().split('\n').map(s => s.trim()).filter(Boolean)
  } catch (err) {
    console.error('capture-one getSelectedPhotos failed:', err)
    throw new Error('Could not connect to Capture One. Please make sure Capture One is running with a document open.', { cause: err })
  }
}

/** 向 Capture One 发送 "重新加载元数据" 指令 */
export async function reloadMetadata(): Promise<void> {
  const appName = await getCaptureOneAppName()
  if (!appName) {
    throw new Error('Could not connect to Capture One to reload metadata. Please make sure Capture One is running with a document open.')
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
    throw new Error('Could not connect to Capture One to reload metadata. Please make sure Capture One is running with a document open.', { cause: err })
  }
}
