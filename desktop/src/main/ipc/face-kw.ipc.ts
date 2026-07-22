import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateNumber, wrapHandler } from './helpers'
import type { WritebackOptions } from '@gather/shared'
import { FaceKwService } from '../services/face-kw/face-kw.service'
import { WritebackService } from '../services/writeback/writeback.service'
import { SettingsService } from '../services/settings'
import { getServices } from '../bootstrap'

export function registerFaceKwHandlers(registry: CommandRegistry): void {
  const { faceKwService, writebackService, faceRepo } = getServices()
  const settings = SettingsService.getInstance()
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

      await faceKwService.analyze(sessionId, detectorPath, encoderPath, eps, minSamples, onProgress)
      return ok({ done: true })
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
      const photoId = validateString(params.photoId, 'photoId')
      await faceKwService.removeMember(sessionId, clusterId, photoId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.preview',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = (params.options ?? {}) as WritebackOptions
      return ok(await writebackService.preview(sessionId, 'face_kw', options))
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

      const clusters = faceRepo.getClusters(sessionId, true)
      const photoKeywords = new Map<string, string[]>()
      for (const cluster of clusters) {
        if (cluster.binding?.keywords?.length) {
          for (const member of cluster.members ?? []) {
            const existing = photoKeywords.get(member.photo_id) ?? []
            for (const kw of cluster.binding.keywords) {
              if (!existing.includes(kw)) {
                existing.push(kw)
              }
            }
            photoKeywords.set(member.photo_id, existing)
          }
        }
      }

      const enrichedItems = items
        .map((item) => {
          const bindingKeywords = photoKeywords.get(item.photoId)
          if (bindingKeywords?.length) {
            return { ...item, keywords: [...new Set([...item.keywords, ...bindingKeywords])] }
          }
          return null
        })
        .filter((item): item is NonNullable<typeof item> => item !== null)

      return ok(await writebackService.execute(sessionId, 'face_kw', enrichedItems))
    }),
  )

  registry.register(
    'fkw.confirm_sync',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await writebackService.confirmSync(sessionId)
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
      return ok(await writebackService.cleanup(sessionId))
    }),
  )

  registry.register(
    'fkw.cleanup',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Cleanup requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.cleanup(sessionId))
    }),
  )
}
