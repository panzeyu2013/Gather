import { t as defaultT, type TypedTFunction } from '../locales'

export function getPathBasename(filepath: string): string {
  return filepath.replace(/[\\/]+$/, '').split(/[\\/]/).pop() ?? ''
}

export function getCommonParentPath(filepaths: string[]): string {
  if (filepaths.length === 0) return ''
  const getParent = (filepath: string) => {
    const normalized = filepath.replace(/[\\/]+$/, '')
    const separatorIndex = Math.max(normalized.lastIndexOf('/'), normalized.lastIndexOf('\\'))
    return separatorIndex > 0 ? normalized.slice(0, separatorIndex) : ''
  }
  const directories = filepaths.map(getParent)
  let candidate = directories[0]
  while (candidate) {
    const prefix = `${candidate}${candidate.includes('\\') ? '\\' : '/'}`
    if (directories.every((directory) => directory === candidate || directory.startsWith(prefix))) {
      return candidate
    }
    candidate = getParent(candidate)
  }
  return ''
}

export function importFailureMessage(
  added: number,
  failedFiles: string[],
  sourceLabel = '',
  translator: TypedTFunction = defaultT,
): string {
  const examples = failedFiles
    .slice(0, 3)
    .map((filepath) => filepath.split(/[/\\]/).pop() ?? filepath)
    .join(translator('list.separator'))
  const remaining = failedFiles.length > 3
    ? translator('dashboard.sessionImportMore', { count: failedFiles.length })
    : ''
  return translator('dashboard.sessionImportFailure', {
    added,
    source: sourceLabel || translator('dashboard.sessionImportSource'),
    examples,
    remaining,
  })
}
