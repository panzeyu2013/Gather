import { app } from 'electron'
import { join, isAbsolute, resolve } from 'path'
import { existsSync, mkdirSync } from 'fs'
import { isValidOnnxModel } from './onnx-validator'

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

export function resolveExecutionProviders(
  provider: string,
  platform: NodeJS.Platform = process.platform,
): string[] {
  if (provider !== 'auto') {
    const primary = normalizeProviderName(provider)
    return primary === 'cpu' ? ['cpu'] : [primary, 'cpu']
  }

  switch (platform) {
    case 'darwin':
      return ['coreml', 'cpu']
    case 'win32':
      return ['dml', 'cpu']
    default:
      return ['cpu']
  }
}

/**
 * Detector execution providers. Automatic selection on macOS now *attempts*
 * CoreML first with CPU as the fallback within the provider list; SCRFD's
 * dynamic spatial outputs are known to fail in the CoreML EP, so the
 * inference worker additionally validates the created session with a warmup
 * run and rebuilds it on CPU when the accelerated path cannot actually run
 * the model (see face-inference-fallback.ts). Explicit provider choices
 * ('cpu' / 'coreml') remain honored exactly as configured.
 */
export function resolveDetectorExecutionProviders(
  provider: string,
  platform: NodeJS.Platform = process.platform,
): string[] {
  return resolveExecutionProviders(provider, platform)
}

export function getAutoBackend(): string {
  switch (process.platform) {
    case 'darwin': return 'coreml'
    case 'win32': return 'dml'
    default: return 'cpu'
  }
}

export function getAutoBackendLabel(): string {
  // Main-side label map (same mechanism as the app menu): the renderer shows
  // this label via the settings IPC payload, so the label is resolved against
  // the app locale instead of shipping zh copy from the main process.
  const isZh = app.getLocale().toLowerCase().startsWith('zh')
  switch (process.platform) {
    case 'darwin': return isZh ? 'CoreML（失败自动回退 CPU）' : 'CoreML (falls back to CPU on failure)'
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

export interface FaceModelPresence {
  detectorPath: string
  encoderPath: string
  detectorPresent: boolean
  encoderPresent: boolean
}

/**
 * A model is only "present" when it is a structurally valid, non-empty ONNX
 * file. Zero-byte files, 1-byte garbage, and files truncated mid-download are
 * not usable and must not be reported as installed.
 */
async function modelIsUsable(modelPath: string): Promise<boolean> {
  return isValidOnnxModel(modelPath)
}

/**
 * Resolve the configured face model paths and report whether each model file
 * is present on disk. Shared by `settings.get_ml_status` and the face module's
 * model-status commands so the presence logic cannot drift apart.
 */
export async function getFaceModelPresence(
  settings: { get: (key: string, fallback?: string) => string },
): Promise<FaceModelPresence> {
  const detectorPath = settings.get('detector_model_path', 'models/face_detector.onnx')
  const encoderPath = settings.get('encoder_model_path', 'models/face_encoder.onnx')
  const detectorResolved = resolveModelPath(detectorPath)
  const encoderResolved = resolveModelPath(encoderPath)
  const [detectorPresent, encoderPresent] = await Promise.all([
    modelIsUsable(detectorResolved),
    modelIsUsable(encoderResolved),
  ])
  return {
    detectorPath: detectorResolved,
    encoderPath: encoderResolved,
    detectorPresent,
    encoderPresent,
  }
}
