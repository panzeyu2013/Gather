import { statSync } from 'node:fs'
import { resolve, extname } from 'node:path'

export function parseImportDeepLink(
  url: string,
  supportedExtensions: ReadonlySet<string>,
): string[] {
  const parsed = new URL(url)
  if (parsed.protocol !== 'gather:' || parsed.hostname !== 'import') return []

  const files: string[] = []
  for (const value of parsed.searchParams.getAll('file').filter(Boolean)) {
    // URLSearchParams already percent-decodes values. Decoding again breaks
    // valid filenames containing a literal percent sign.
    const filepath = resolve(value)
    if (!supportedExtensions.has(extname(filepath).toLowerCase())) continue
    try {
      if (statSync(filepath).isFile()) files.push(filepath)
    } catch {
      // Invalid, inaccessible, or stale paths are ignored individually.
    }
  }
  return [...new Set(files)]
}
