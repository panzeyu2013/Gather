import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import { getAutoBackend, getAutoBackendLabel, getAvailableBackends, getModelResourcesDir, resolveModelPath } from '../services/face-kw/provider'
import { existsSync } from 'fs'
import type { SettingsService } from '../services/settings/settings.service'

export function registerSettingsHandlers(registry: CommandRegistry, svc: SettingsService): void {

  registry.register('settings.get_all', wrapHandler(async () => ok(svc.getAll())))

  registry.register('settings.get', wrapHandler(async (params) => {
    const key = validateString(params.key, 'key', 256)
    return ok(svc.get(key))
  }))

  registry.register('settings.set', wrapHandler(async (params) => {
    const key = validateString(params.key, 'key', 256)
    const value = validateString(params.value, 'value', 4096, true)
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
        secondaryDetectInputSize: svc.getNumber('detect_secondary_input_size', 128),
        previewMaxDimension: svc.getNumber('face_preview_max_dimension', 2048),
        encoderInputSize: svc.getNumber('encoder_input_size', 112),
        embeddingDim: svc.getNumber('embedding_dim', 512),
      },
    })
  }))
}
