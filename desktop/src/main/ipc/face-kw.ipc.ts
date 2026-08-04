import type { CommandRegistry } from './registry'
import { ok, validateString, validateNumber, wrapHandler } from './helpers'
import type { WritebackOptions } from '@gather/shared'
import {
  type FaceKwService,
  validateFaceClusteringParameters,
} from '../services/face-kw/face-kw.service'
import { getFaceModelPresence } from '../services/face-kw/provider'
import type { WritebackService } from '../services/writeback/writeback.service'
import type { FaceRepository } from '../db/repositories/face.repo'
import type { SettingsService } from '../services/settings/settings.service'
import { buildFaceKeywordAdditions } from '../services/writeback/writeback-planners'
import type { JobService } from '../services/jobs/job.service'
import { getXmpSidecarPath } from '../services/xmp/xmp-sidecar-writer'

export function registerFaceKwHandlers(
  registry: CommandRegistry,
  faceKwService: FaceKwService,
  writebackService: WritebackService,
  faceRepo: FaceRepository,
  settings: SettingsService,
  jobs: JobService,
): void {
  jobs.registerExecutor('face.analyze', (job, context) => {
    const checkpoint = job.checkpoint
    context.signal.addEventListener('abort', () => {
      void faceKwService.cancel(job.scopeId)
    }, { once: true })
    return faceKwService.analyze(
      job.scopeId,
      String(checkpoint.detectorPath),
      String(checkpoint.encoderPath),
      typeof checkpoint.eps === 'number' ? checkpoint.eps : undefined,
      typeof checkpoint.minSamples === 'number' ? checkpoint.minSamples : undefined,
      progress => context.updateProgress({
        ...progress,
        checkpoint,
      }),
    )
  })
  registry.register(
    'fkw.analyze',
    wrapHandler(async (params, event) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const eps = typeof params.eps === 'number' ? params.eps : settings.getNumber('default_eps', 0.6)
      const minSamples = typeof params.minSamples === 'number' ? params.minSamples : settings.getNumber('default_min_samples', 2)
      validateFaceClusteringParameters(eps, minSamples)

      const detectorPath = typeof params.detectorPath === 'string' ? params.detectorPath : settings.get('detector_model_path', 'models/face_detector.onnx')
      const encoderPath = typeof params.encoderPath === 'string' ? params.encoderPath : settings.get('encoder_model_path', 'models/face_encoder.onnx')

      const job = jobs.create({
        type: 'face.analyze',
        scopeType: 'session',
        scopeId: sessionId,
        dedupeKey: `face.analyze:${sessionId}:${detectorPath}:${encoderPath}:${eps}:${minSamples}`,
        checkpoint: { detectorPath, encoderPath, eps, minSamples },
      })
      const result = await jobs.waitForResult(job.id)
      event?.sender.send('gather:event', 'progress', {
        sessionId,
        current: 1,
        total: 1,
        message: 'Face analysis complete',
      })
      return ok(result)
    }),
  )

  registry.register(
    'face.models_status',
    wrapHandler(async () => {
      const presence = getFaceModelPresence(settings)
      return ok(presence)
    }),
  )

  registry.register(
    'fkw.cancel_analysis',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      jobs.cancelScope('face.analyze', sessionId)
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
      validateFaceClusteringParameters(eps, minSamples)
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
      if (
        !Array.isArray(params.keywords) ||
        params.keywords.some(keyword => typeof keyword !== 'string')
      ) {
        throw new Error('keywords must be an array of strings')
      }
      const keywords = params.keywords as string[]
      await faceKwService.bindCluster(sessionId, clusterId, roleName, keywords)
      return ok({ done: true })
    }),
  )

  registry.register(
    'fkw.unbind',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Unbinding written face keywords requires confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const clusterId = validateNumber(params.clusterId, 'clusterId')
      const cluster = faceRepo.getClusters(sessionId, true)
        .find(candidate => candidate.id === clusterId)
      if (!cluster) throw new Error('Cluster not found')
      const protectedByPath = new Map<string, Set<string>>()
      for (const remaining of faceRepo.getClusters(sessionId, true)) {
        if (remaining.id === clusterId) continue
        if (!remaining.binding) continue
        for (const member of remaining.members ?? []) {
          const xmpPath = getXmpSidecarPath(member.photo_path)
          const protectedKeywords = protectedByPath.get(xmpPath) ?? new Set<string>()
          ;[remaining.binding.roleName, ...remaining.binding.keywords]
            .map(keyword => keyword.trim())
            .filter(Boolean)
            .forEach(keyword => protectedKeywords.add(keyword))
          protectedByPath.set(xmpPath, protectedKeywords)
        }
      }
      const entries = (cluster.members ?? []).map(member => {
        const xmpPath = getXmpSidecarPath(member.photo_path)
        const protectedKeywords = protectedByPath.get(xmpPath) ?? new Set<string>()
        return {
          photoId: member.photo_id,
          xmpPath,
          keywords: [cluster.binding?.roleName ?? '', ...(cluster.binding?.keywords ?? [])]
            .map(keyword => keyword.trim())
            .filter(Boolean)
            .filter(keyword => !protectedKeywords.has(keyword)),
        }
      })
      const removedKeywords = await writebackService.removeOwnedFaceKeywords(
        sessionId,
        entries,
      )
      await faceKwService.unbindCluster(sessionId, clusterId)
      return ok({ done: true, removedKeywords })
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
