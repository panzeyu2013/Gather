import { SettingsService } from '../services/settings'
import { getAutoBackend, getAutoBackendLabel } from '../services/face-kw/provider'
import { INPUT_SIZE } from '../services/face-kw/face-detector'
import { ENCODER_INPUT_SIZE, EMBEDDING_DIM } from '../services/face-kw/face-encoder'
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

    return ok({
      platform: process.platform,
      autoBackend: getAutoBackend(),
      autoBackendLabel: getAutoBackendLabel(),
      provider,
      isAuto,
      detectorModel: {
        path: detectorPath,
        exists: existsSync(detectorPath),
      },
      encoderModel: {
        path: encoderPath,
        exists: existsSync(encoderPath),
      },
      modelInfo: {
        detectInputSize: INPUT_SIZE,
        encoderInputSize: ENCODER_INPUT_SIZE,
        embeddingDim: EMBEDDING_DIM,
      },
    })
  }))
}
