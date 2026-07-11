import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr, WritebackOptions } from '@gather/shared'
import { FaceKwService } from '../services/face-kw/face-kw.service'
import { WritebackService } from '../services/writeback/writeback.service'
import { SessionRepository } from '../db/repositories/session.repo'
import { PhotoRepository } from '../db/repositories/photo.repo'
import { FaceRepository } from '../db/repositories/face.repo'
import { WritebackRepository } from '../db/repositories/writeback.repo'
import { XmpWriter } from '../services/xmp/xmp-writer'
import { SettingsService } from '../services/settings'

function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

function err(error: string): ResponseErr {
  return { ok: false, error }
}

function validateString(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(`Invalid ${name}: must be a non-empty string`)
  }
  return value.trim()
}

function validateNumber(value: unknown, name: string): number {
  if (typeof value !== 'number' || isNaN(value)) {
    throw new Error(`Invalid ${name}: must be a number`)
  }
  return value
}

function wrapHandler(handler: (params: Record<string, unknown>, event?: Electron.IpcMainInvokeEvent) => unknown) {
  return async (params: unknown, event?: Electron.IpcMainInvokeEvent) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>, event)
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err(message)
    }
  }
}

let service: FaceKwService | null = null

function getService(): FaceKwService {
  if (!service) {
    service = new FaceKwService(new PhotoRepository(), new SessionRepository(), new FaceRepository())
  }
  return service
}

let writebackService: WritebackService | null = null

function getWritebackService(): WritebackService {
  if (!writebackService) {
    writebackService = new WritebackService(
      new WritebackRepository(),
      new XmpWriter(),
      new PhotoRepository(),
      new SessionRepository(),
    )
  }
  return writebackService
}

let faceRepo: FaceRepository | null = null

function getFaceRepo(): FaceRepository {
  if (!faceRepo) {
    faceRepo = new FaceRepository()
  }
  return faceRepo
}

export function registerFaceKwHandlers(registry: CommandRegistry): void {
  const settings = SettingsService.getInstance()
  registry.register(
    'fkw.analyze',
    wrapHandler(async (params, event) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const eps = typeof params.eps === 'number' ? params.eps : settings.getNumber('default_eps', 0.6)
      const minSamples = typeof params.minSamples === 'number' ? params.minSamples : settings.getNumber('default_min_samples', 3)

      const detectorPath = typeof params.detectorPath === 'string' ? params.detectorPath : settings.get('detector_model_path', 'models/face_detector.onnx')
      const encoderPath = typeof params.encoderPath === 'string' ? params.encoderPath : settings.get('encoder_model_path', 'models/face_encoder.onnx')

      const onProgress = (progress: { current: number; total: number; message: string }) => {
        event?.sender.send('gather:event', 'progress', {
          sessionId,
          ...progress,
        })
      }

      await getService().analyze(sessionId, detectorPath, encoderPath, eps, minSamples, onProgress)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.cancel_analysis',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await getService().cancel(sessionId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.clusters',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const data = await getService().getClusters(sessionId)
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
      await getService().bindCluster(sessionId, clusterId, roleName, keywords)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.unbind',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      await getService().unbindCluster(sessionId, clusterId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.merge',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const source = validateNumber(params.source, 'source')
      const target = validateNumber(params.target, 'target')
      await getService().mergeClusters(sessionId, source, target)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.remove_member',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      const photoId = validateString(params.photoId, 'photoId')
      await getService().removeMember(sessionId, clusterId, photoId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.preview',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = (params.options ?? {}) as WritebackOptions
      return ok(await getWritebackService().preview(sessionId, 'face_kw', options))
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

      const clusters = getFaceRepo().getClusters(sessionId, true)
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

      const enrichedItems = items.map((item) => {
        const bindingKeywords = photoKeywords.get(item.photoId)
        if (bindingKeywords?.length) {
          return { ...item, keywords: [...new Set([...item.keywords, ...bindingKeywords])] }
        }
        return item
      })

      return ok(await getWritebackService().execute(sessionId, 'face_kw', enrichedItems))
    }),
  )

  registry.register(
    'fkw.confirm_sync',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await getWritebackService().confirmSync(sessionId)
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
      return ok(await getWritebackService().cleanup(sessionId))
    }),
  )

  registry.register(
    'fkw.cleanup',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Cleanup requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await getWritebackService().cleanup(sessionId))
    }),
  )
}
