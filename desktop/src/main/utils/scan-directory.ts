// desktop/src/main/utils/scan-directory.ts
import { readdir, stat } from 'fs/promises'
import { join } from 'path'
import type { ScanResult } from '@gather/shared'

// Bound the files array returned over IPC so scanning a huge tree cannot
// exhaust the main-process memory. This is an IPC/memory bound, not a product
// limit: scannedTotal keeps counting past it so callers can report the cut.
export const MAX_SCANNED_FILES = 50_000

export interface ScanDirectoryOptions {
  limit?: number
  supportedExtensions: Set<string>
}

export async function scanDirectory(
  dirPath: string,
  options: ScanDirectoryOptions,
): Promise<ScanResult> {
  const limit = options.limit ?? MAX_SCANNED_FILES
  const files: string[] = []
  let scannedTotal = 0
  const scan = async (directory: string): Promise<void> => {
    const entries = await readdir(directory, { withFileTypes: true })
    for (const entry of entries) {
      // Do not follow symlinks: a link may escape the selected directory or
      // introduce a directory cycle.
      if (entry.isSymbolicLink()) continue
      const fullPath = join(directory, entry.name)
      try {
        if (entry.isDirectory()) {
          await scan(fullPath)
        } else if (entry.isFile()) {
          const ext = '.' + entry.name.split('.').pop()?.toLowerCase()
          if (options.supportedExtensions.has(ext)) {
            scannedTotal += 1
            if (files.length < limit) files.push(fullPath)
          }
        }
      } catch {
        // One unreadable child must not discard the rest of the selected
        // directory. A failure at the root is still reported below.
      }
    }
  }
  try {
    const root = await stat(dirPath)
    if (!root.isDirectory()) throw new Error('SCAN_INVALID_DIR')
    await scan(dirPath)
  } catch (error) {
    if (error instanceof Error && error.message === 'SCAN_INVALID_DIR') throw error
    throw new Error('SCAN_READ_FAILED', { cause: error })
  }
  return { files, truncated: scannedTotal > files.length, scannedTotal, limit }
}
