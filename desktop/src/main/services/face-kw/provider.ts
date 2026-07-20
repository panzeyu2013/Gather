import { app } from 'electron'
import { join, isAbsolute, resolve } from 'path'
import { existsSync } from 'fs'

export function resolveModelPath(modelPath: string): string {
  if (isAbsolute(modelPath)) return modelPath
  if (existsSync(modelPath)) return modelPath
  try {
    const candidates = [
      join(process.resourcesPath, modelPath),
      join(app.getAppPath(), 'resources', modelPath),
      join(app.getAppPath(), modelPath),
      resolve(modelPath),
    ]
    for (const c of candidates) {
      if (existsSync(c)) return c
    }
  } catch {
    // app.getAppPath() may throw if not ready; fall through
  }
  return modelPath
}

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

export interface BackendOption {
  value: string
  label: string
}

export function getAvailableBackends(): BackendOption[] {
  switch (process.platform) {
    case 'darwin':
      return [
        { value: 'CoreMLExecutionProvider', label: 'CoreML' },
        { value: 'CPU', label: 'CPU' },
      ]
    case 'win32':
      return [
        { value: 'DmlExecutionProvider', label: 'DirectML' },
        { value: 'CPU', label: 'CPU' },
      ]
    default:
      return [
        { value: 'CPU', label: 'CPU' },
      ]
  }
}

export function getModelResourcesDir(): string {
  const fromResources = join(process.resourcesPath, 'models')
  if (existsSync(fromResources)) return fromResources
  const fromApp = join(app.getAppPath(), 'resources', 'models')
  if (existsSync(fromApp)) return fromApp
  if (existsSync('resources/models')) return join(process.cwd(), 'resources', 'models')
  return fromApp
}
