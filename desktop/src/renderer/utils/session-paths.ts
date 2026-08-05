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
  sourceLabel = '文件',
): string {
  const examples = failedFiles
    .slice(0, 3)
    .map((filepath) => filepath.split(/[/\\]/).pop() ?? filepath)
    .join('、')
  const remaining = failedFiles.length > 3
    ? ` 等 ${failedFiles.length} 个`
    : ''
  return `${added} 张照片已导入；${sourceLabel}读取失败：${examples}${remaining}`
}
