import { createHash } from 'crypto'
import { readFile, stat } from 'fs/promises'
import * as path from 'path'

/**
 * Cryptographic content fingerprint used to detect external modification of an
 * XMP file between the baseline snapshot and the write. The sha256 forces a
 * full read, so it is only used on the durable write/conflict path, never for
 * list rendering.
 *
 * Returns '' when the file does not exist.
 */
export async function contentFingerprint(filePath: string): Promise<string> {
  try {
    const info = await stat(filePath)
    const content = await readFile(filePath)
    return `${info.size}:${Math.round(info.mtimeMs)}:${createHash('sha256').update(content).digest('hex')}`
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw error
  }
}

/**
 * Cheap staleness key used by the metadata cache: source file size plus
 * { source mtime : sidecar mtime }. Deliberately avoids reading file contents;
 * this is a cache-invalidity hint, not a durability guard.
 */
export async function cacheStalenessKey(photoPath: string): Promise<{
  size: number
  value: string
} | null> {
  try {
    const sourceStat = await stat(photoPath)
    let xmpMtime = 0
    try {
      xmpMtime = (await stat(xmpPathOf(photoPath))).mtimeMs
    } catch {
      // Missing sidecar is represented by zero.
    }
    return {
      size: sourceStat.size,
      value: `${Math.round(sourceStat.mtimeMs)}:${Math.round(xmpMtime)}`,
    }
  } catch {
    // Unreadable files will be handled by extraction.
    return null
  }
}

function xmpPathOf(photoPath: string): string {
  const parsed = path.parse(photoPath)
  return path.join(parsed.dir, `${parsed.name}.xmp`)
}
