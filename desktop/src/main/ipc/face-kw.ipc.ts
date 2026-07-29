import type { CommandRegistry } from './registry'
import { ok, validateString, validateNumber, wrapHandler } from './helpers'
import type { WritebackOptions } from '@gather/shared'
import type { FaceKwService } from '../services/face-kw/face-kw.service'
import type { WritebackService } from '../services/writeback/writeback.service'
import type { FaceRepository } from '../db/repositories/face.repo'
import type { SettingsService } from '../services/settings/settings.service'
import { buildFaceKeywordAdditions } from '../services/writeback/writeback-planners'

export function registerFaceKwHandlers(
  registry: CommandRegistry,
  faceKwService: FaceKwService,
  writebackService: WritebackService,
  faceRepo: FaceRepository,
  settings: SettingsService,
): void {
  registry.register(
    'fkw.analyze',
    wrapHandler(async (params, event) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const eps = typeof params.eps === 'number' ? params.eps : settings.getNumber('default_eps', 0.6)
      const minSamples = typeof params.minSamples === 'number' ? params.minSamples : settings.getNumber('default_min_samples', 2)

      const detectorPath = typeof params.detectorPath === 'string' ? params.detectorPath : settings.get('detector_model_path', 'models/face_detector.onnx')
      const encoderPath = typeof params.encoderPath === 'string' ? params.encoderPath : settings.get('encoder_model_path', 'models/face_encoder.onnx')

      const onProgress = (progress: { current: number; total: number; message: string }) => {
        event?.sender.send('gather:event', 'progress', {
          sessionId,
          ...progress,
        })
      }

      const result = await faceKwService.analyze(
        sessionId,
        detectorPath,
        encoderPath,
        eps,
        minSamples,
        onProgress,
      )
      return ok(result)
    }),
  )

  registry.register(
    'fkw.cancel_analysis',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await faceKwService.cancel(sessionId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.recluster',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const eps = typeof params.eps === 'number'
        ? params.eps
        : settings.getNumber('default_eps', 0.6)
      const minSamples = typeof params.minSamples === 'number'
        ? params.minSamples
        : settings.getNumber('default_min_samples', 2)
      await faceKwService.recluster(sessionId, eps, minSamples)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.clusters',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const data = await faceKwService.getClusters(sessionId)
      return ok(data)
    }),
  )

  registry.register(
    'fkw.bind',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      const roleName = validateString(params.roleName, 'roleName')
      const keywords = Array.isArray(params.keywords) ? (params.keywords as string[]) : []
      await faceKwService.bindCluster(sessionId, clusterId, roleName, keywords)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.unbind',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      await faceKwService.unbindCluster(sessionId, clusterId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.merge',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const source = validateNumber(params.source, 'source')
      const target = validateNumber(params.target, 'target')
      await faceKwService.mergeClusters(sessionId, source, target)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.get_cluster_thumbnail',
    wrapHandler(async (params) => {
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      const base64 = await faceKwService.getClusterThumbnail(clusterId)
      return ok({ base64 })
    }),
  )

  registry.register(
    'fkw.remove_member',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      const memberId = validateNumber(params.memberId, 'memberId')
      await faceKwService.removeMember(sessionId, clusterId, memberId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.preview',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = (params.options ?? {}) as WritebackOptions

      const clusters = faceRepo.getClusters(sessionId, true)
      const additions = buildFaceKeywordAdditions(clusters)
      const boundPhotoIds = new Set(additions.keys())

      return ok(await writebackService.preview(
        sessionId,
        'face_kw',
        options,
        boundPhotoIds,
        additions,
      ))
    }),
  )

  registry.register(
    'fkw.writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Writeback requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const items = (params.items ?? []) as import('@gather/shared').WritebackItem[]
      if (!Array.isArray(items)) {
        throw new Error('Invalid items: must be an array')
      }

      return ok(await writebackService.execute(sessionId, 'face_kw', items))
    }),
  )

  registry.register(
    'fkw.confirm_sync',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await writebackService.confirmSync(sessionId, 'face_kw')
      return ok(true)
    }),
  )

  registry.register(
    'fkw.confirm_cleanup',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const confirmed = typeof params.confirmed === 'boolean' ? params.confirmed : false
      if (confirmed !== true) {
        throw new Error('Cleanup must be confirmed')
      }
      return ok(await writebackService.cleanup(sessionId, 'face_kw'))
    }),
  )

  registry.register(
    'fkw.cleanup',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Cleanup requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.cleanup(sessionId, 'face_kw'))
    }),
  )
}
