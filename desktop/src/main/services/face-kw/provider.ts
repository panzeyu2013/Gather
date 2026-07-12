export function resolveExecutionProviders(provider: string): string[] {
  if (provider !== 'auto') {
    if (provider === 'CPU') return ['CPUExecutionProvider']
    if (provider === 'CUDA') return ['CUDAExecutionProvider', 'CPUExecutionProvider']
    if (provider === 'CoreMLExecutionProvider') return ['CoreMLExecutionProvider', 'CPUExecutionProvider']
    if (provider === 'DmlExecutionProvider') return ['DmlExecutionProvider', 'CPUExecutionProvider']
    return [provider, 'CPUExecutionProvider']
  }

  switch (process.platform) {
    case 'darwin':
      return ['CoreMLExecutionProvider', 'CPUExecutionProvider']
    case 'win32':
      return ['DmlExecutionProvider', 'CPUExecutionProvider']
    default:
      return ['CPUExecutionProvider']
  }
}

export function getAutoBackend(): string {
  switch (process.platform) {
    case 'darwin': return 'CoreMLExecutionProvider'
    case 'win32': return 'DmlExecutionProvider'
    default: return 'CPUExecutionProvider'
  }
}

export function getAutoBackendLabel(): string {
  switch (process.platform) {
    case 'darwin': return 'CoreML'
    case 'win32': return 'DirectML'
    default: return 'CPU'
  }
}
