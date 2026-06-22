// src/main/capture-one.ts
// Capture One 集成 — osascript 桥接

import { execFile as execFileCb } from 'child_process'
import { promisify } from 'util'

const execFile = promisify(execFileCb)

async function execAppleScript(script: string, retries = 3): Promise<string> {
  for (let i = 0; i < retries; i++) {
    try {
      const { stdout } = await execFile('osascript', ['-e', script], { timeout: 15000 })
      return stdout
    } catch (err) {
      if (i === retries - 1) throw err
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
  // NOTE: Regex only allows exact matches like "Capture One" or "Capture One 16".
  // If Capture One releases a version with a suffix or non-numeric tag, this will reject it.
  if (!/^Capture One( \d+)?$/.test(appName.trim())) {
    throw new Error(`Potentially unsafe process name rejected: ${appName}`)
  }
  return appName
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

  const script = `
tell application "${appName}"
  try
    reload metadata of current document
  end try
end tell
`
  try {
    await execAppleScript(script)
    // Allow Capture One time to finish reloading metadata.
    // The 500ms delay is a pragmatic choice; there is no callback from C1.
    // If C1 metadata reload takes longer, results may be stale on the next poll.
    // NOTE: This hardcoded delay is a fragility point. It should be replaced with
    // retry-based polling (e.g. poll for a metadata change signal) in the future.
    await new Promise(r => setTimeout(r, 500))
  } catch (err) {
    console.error('capture-one reloadMetadata failed:', err)
    throw new Error('Could not connect to Capture One to reload metadata. Please make sure Capture One is running with a document open.', { cause: err })
  }
}
