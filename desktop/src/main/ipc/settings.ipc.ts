import { SettingsService } from '../services/settings'
import { getAutoBackend, getAutoBackendLabel, getAvailableBackends, getModelResourcesDir, resolveModelPath } from '../services/face-kw/provider'
import { existsSync } from 'fs'
import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'

function ok<T>(data: T): ResponseOk<T> { return { ok: true, data } }
function err(error: string): ResponseErr { return { ok: false, error } }

function wrapHandler(handler: (params: Record<string, unknown>) => unknown) {
  return async (params: unknown) => {
    try { return await handler((params ?? {}) as Record<string, unknown>) }
    catch (e) { return err(e instanceof Error ? e.message : 'Unknown error') }
  }
}

export function registerSettingsHandlers(registry: CommandRegistry): void {
  const svc = SettingsService.getInstance()

  registry.register('settings.get_all', wrapHandler(async () => ok(svc.getAll())))

  registry.register('settings.get', wrapHandler(async (params) => {
    const key = params.key as string
    if (!key) throw new Error('Missing key')
    return ok(svc.get(key))
  }))

  registry.register('settings.set', wrapHandler(async (params) => {
    const key = params.key as string
    const value = params.value as string
    if (!key || value === undefined) throw new Error('Missing key or value')
    svc.set(key, value)
    return ok({ done: true })
  }))

  registry.register('settings.reset', wrapHandler(async () => {
    svc.reset()
    return ok(svc.getAll())
  }))

  registry.register('settings.get_ml_status', wrapHandler(async () => {
    const detectorPath = svc.get('detector_model_path', 'models/face_detector.onnx')
    const encoderPath = svc.get('encoder_model_path', 'models/face_encoder.onnx')
    const provider = svc.get('onnx_provider', 'auto')
    const isAuto = provider === 'auto'
    const resolvedDetector = resolveModelPath(detectorPath)
    const resolvedEncoder = resolveModelPath(encoderPath)

    return ok({
      platform: process.platform,
      autoBackend: getAutoBackend(),
      autoBackendLabel: getAutoBackendLabel(),
      provider,
      isAuto,
      availableBackends: getAvailableBackends(),
      modelResourcesDir: getModelResourcesDir(),
      detectorModel: {
        path: detectorPath,
        resolvedPath: resolvedDetector,
        exists: existsSync(resolvedDetector),
      },
      encoderModel: {
        path: encoderPath,
        resolvedPath: resolvedEncoder,
        exists: existsSync(resolvedEncoder),
      },
      modelInfo: {
        detectInputSize: svc.getNumber('detect_input_size', 640),
        encoderInputSize: svc.getNumber('encoder_input_size', 112),
        embeddingDim: svc.getNumber('embedding_dim', 512),
      },
    })
  }))
}
