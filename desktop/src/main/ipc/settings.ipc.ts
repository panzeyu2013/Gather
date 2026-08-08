import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import { getAutoBackend, getAutoBackendLabel, getAvailableBackends, getFaceModelPresence, getModelResourcesDir } from '../services/face-kw/provider'
import type { SettingsService } from '../services/settings/settings.service'
import { isAppLocale } from '../locale'
import { setAppLocale } from '../menu'

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

  // Language switch (i18n P2 收尾): persist the `ui_language` override AND
  // rebuild the application menu in the same handler, so menu copy follows
  // the new locale immediately (design_improvements.md 4.4.2). Values other
  // than 'zh-CN'/'en' are rejected before anything is written.
  registry.register('settings.set_language', wrapHandler(async (params) => {
    const language = (params ?? {}).language
    if (!isAppLocale(language)) {
      throw new Error('SETTINGS_LANGUAGE_INVALID')
    }
    svc.set('ui_language', language)
    setAppLocale(language)
    return ok({ language })
  }))

  registry.register('settings.get_ml_status', wrapHandler(async () => {
    const provider = svc.get('onnx_provider', 'auto')
    const isAuto = provider === 'auto'
    const presence = await getFaceModelPresence(svc)

    return ok({
      platform: process.platform,
      autoBackend: getAutoBackend(),
      autoBackendLabel: getAutoBackendLabel(),
      provider,
      isAuto,
      availableBackends: getAvailableBackends(),
      modelResourcesDir: getModelResourcesDir(),
      detectorModel: {
        path: svc.get('detector_model_path', 'models/face_detector.onnx'),
        resolvedPath: presence.detectorPath,
        exists: presence.detectorPresent,
      },
      encoderModel: {
        path: svc.get('encoder_model_path', 'models/face_encoder.onnx'),
        resolvedPath: presence.encoderPath,
        exists: presence.encoderPresent,
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
