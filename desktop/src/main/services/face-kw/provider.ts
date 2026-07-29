import { app } from 'electron'
import { join, isAbsolute, resolve } from 'path'
import { existsSync, mkdirSync } from 'fs'

function getModelFilename(modelPath: string): string {
  return modelPath.replace(/^models[/\\]/, '')
}

export function resolveModelPath(modelPath: string): string {
  if (isAbsolute(modelPath)) return modelPath
  if (existsSync(modelPath)) return resolve(modelPath)

  try {
    const filename = getModelFilename(modelPath)
    const candidates = [
      join(app.getPath('userData'), 'models', filename),
      join(process.resourcesPath, 'models', filename),
      resolve(modelPath),
    ]

    return candidates.find((c) => existsSync(c)) ?? candidates[0]
  } catch {
    return resolve(modelPath)
  }
}

function normalizeProviderName(raw: string): string {
  const lower = raw.toLowerCase()
  if (lower === 'coreml' || lower === 'coremlexecutionprovider') return 'coreml'
  if (lower === 'cpu' || lower === 'cpuexecutionprovider') return 'cpu'
  if (lower === 'cuda' || lower === 'cudaexecutionprovider') return 'cuda'
  if (lower === 'dml' || lower === 'dmlexecutionprovider') return 'dml'
  return lower
}

export function resolveExecutionProviders(provider: string): string[] {
  if (provider !== 'auto') {
    const primary = normalizeProviderName(provider)
    return primary === 'cpu' ? ['cpu'] : [primary, 'cpu']
  }

  switch (process.platform) {
    case 'darwin':
      return ['coreml', 'cpu']
    case 'win32':
      return ['dml', 'cpu']
    default:
      return ['cpu']
  }
}

/**
 * SCRFD's dynamic spatial outputs currently fail in ONNX Runtime's CoreML EP
 * when the same model is evaluated at both 128 and 640. Keep automatic face
 * detection on CPU on macOS; the fixed-shape ArcFace encoder can still use
 * CoreML. An explicit CoreML choice is honored and protected by runtime
 * fallback in the detector.
 */
export function resolveDetectorExecutionProviders(provider: string): string[] {
  if (provider === 'auto' && process.platform === 'darwin') return ['cpu']
  return resolveExecutionProviders(provider)
}

export function getAutoBackend(): string {
  switch (process.platform) {
    case 'darwin': return 'coreml'
    case 'win32': return 'dml'
    default: return 'cpu'
  }
}

export function getAutoBackendLabel(): string {
  switch (process.platform) {
    case 'darwin': return 'CPU 检测 + CoreML 识别'
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
        { value: 'coreml', label: 'CoreML' },
        { value: 'cpu', label: 'CPU' },
      ]
    case 'win32':
      return [
        { value: 'dml', label: 'DirectML' },
        { value: 'cpu', label: 'CPU' },
      ]
    default:
      return [
        { value: 'cpu', label: 'CPU' },
      ]
  }
}

export function getModelResourcesDir(): string {
  const fromUserData = join(app.getPath('userData'), 'models')
  if (!existsSync(fromUserData)) {
    try { mkdirSync(fromUserData, { recursive: true }) } catch { /* best effort */ }
  }
  return fromUserData
}
