import { PhotoRepository, type PhotoRow } from '../../db/repositories/photo.repo'
import {
  CullingDecisionRepository,
  type CullingDecisionRow,
} from '../../db/repositories/culling-decision.repo'
import { SimilarityResultRepository } from '../../db/repositories/similarity-result.repo'
import { MetadataCacheRepository } from '../../db/repositories/metadata-cache.repo'
import { MetadataOutboxRepository } from '../../db/repositories/metadata-outbox.repo'
import { CullingHistoryRepository } from '../../db/repositories/culling-history.repo'
import { Database } from '../../db/database'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'
import { MetadataSyncCoordinator } from '../metadata/metadata-sync-coordinator'
import { MetadataMutationService } from '../metadata/metadata-mutation.service'
import { SettingsService } from '../settings/settings.service'
import type {
  AssetCullingState,
  CaptureOneColorLabel,
  CullingAsset,
  CullingFilters,
  CullingGroup,
  CullingImage,
  CullingScope,
  CullingSummary,
  CullingUpdatePatch,
  CullingUpdateResult,
  CullingHistoryEntry,
  CullingHistoryApplyEntry,
  LegacyCullingDecision,
  MetadataSyncStatus,
  MetadataMutationSource,
  PhotoData,
  PickState,
  SimilarityGroup,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

const COLOR_LABELS = new Set<CaptureOneColorLabel>([
  'None',
  'Red',
  'Orange',
  'Yellow',
  'Green',
  'Blue',
  'Pink',
  'Purple',
])

function decisionToPickState(decision: string | undefined): PickState {
  if (decision === 'keep') return 'picked'
  if (decision === 'reject') return 'rejected'
  return 'unreviewed'
}

function pickStateToDecision(pickState: PickState): LegacyCullingDecision {
  if (pickState === 'picked') return 'keep'
  if (pickState === 'rejected') return 'reject'
  return 'pending'
}

function parseJsonRecord(value: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value)
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {}
  } catch {
    return {}
  }
}

function photoRowToData(row: PhotoRow, faceCount: number): PhotoData {
  return {
    id: row.id,
    sessionId: row.session_id,
    filepath: row.filepath,
    filename: row.filename,
    checksum: row.checksum,
    hasExistingXmp: false,
    faceCount,
    width: row.width ?? 0,
    height: row.height ?? 0,
    metadata: parseJsonRecord(row.metadata),
    result: parseJsonRecord(row.result),
    status: row.status,
    assetId: row.asset_id ?? undefined,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

@injectable()
export class CullingService {
  constructor(
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.CULLING_DECISION_REPO)
    private cullingDecisionRepo: CullingDecisionRepository,
    @inject(DI_TOKENS.SIMILARITY_RESULT_REPO)
    private similarityResultRepo: SimilarityResultRepository,
    @inject(DI_TOKENS.METADATA_CACHE_REPO)
    private metadataCacheRepo: MetadataCacheRepository,
    @inject(DI_TOKENS.METADATA_OUTBOX_REPO)
    private metadataOutboxRepo: MetadataOutboxRepository,
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.METADATA_SYNC_COORDINATOR)
    private metadataSync: MetadataSyncCoordinator,
    @inject(DI_TOKENS.METADATA_MUTATION_SERVICE)
    private metadataMutations: MetadataMutationService,
    @inject(DI_TOKENS.SETTINGS_SERVICE)
    private settings: SettingsService,
    @inject(DI_TOKENS.CULLING_HISTORY_REPO)
    private cullingHistoryRepo?: CullingHistoryRepository,
  ) {}

  list(
    sessionId: string,
    scope: CullingScope,
    filters?: CullingFilters,
    requestedGroupId?: string,
  ): CullingAsset[] {
    const photos = this.photoRepo.getBySession(sessionId)
    const decisions = new Map(
      this.cullingDecisionRepo.getBySession(sessionId).map(row => [row.photo_id, row]),
    )
    const cacheRows = new Map(
      this.metadataCacheRepo.getBatch(photos.map(photo => photo.id))
        .map(row => [row.photo_id, row]),
    )
    const outboxByPath = new Map(
      this.metadataOutboxRepo.getBySession(sessionId).map(row => [row.xmp_path, row]),
    )
    const similarityMap = this.getLatestSimilarityMap(sessionId)
    const qualityByPhoto = new Map<string, CullingAsset['quality']>()
    if (photos.length > 0) {
      // Stay below SQLite's parameter limit for very large sessions.
      const qualityRows: Array<{
        requested_photo_id: string
        result_json: string
      }> = []
      for (let index = 0; index < photos.length; index += 800) {
        const chunk = photos.slice(index, index + 800)
        qualityRows.push(...this.db.prepare(`
          SELECT p.id AS requested_photo_id, aa.result_json
          FROM photos p
          JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
          WHERE aa.analysis_type = 'technical_quality'
            AND p.id IN (${chunk.map(() => '?').join(',')})
          ORDER BY aa.updated_at DESC
        `).all(...chunk.map(photo => photo.id)) as Array<{
          requested_photo_id: string
          result_json: string
        }>)
      }
      for (const row of qualityRows) {
      try {
        const parsed = JSON.parse(row.result_json) as {
          photoId?: string
          status?: 'succeeded' | 'failed'
          errorMessage?: string
          qualityScore?: number
          sharpness?: number
          exposure?: number
          subjectSharpness?: number
          closedEyeRisk?: number
          closedEyeProbability?: number
          confidence?: number
          relativeRank?: number
          warnings?: string[]
        }
        if (!qualityByPhoto.has(row.requested_photo_id)) {
          qualityByPhoto.set(row.requested_photo_id, {
            status: parsed.status ?? 'succeeded',
            score: parsed.qualityScore ?? 0,
            sharpness: parsed.sharpness ?? 0,
            exposure: parsed.exposure ?? 0,
            subjectSharpness: parsed.subjectSharpness,
            closedEyeRisk: parsed.closedEyeRisk ?? parsed.closedEyeProbability,
            closedEyeProbability: parsed.closedEyeProbability,
            confidence: parsed.confidence,
            relativeRank: parsed.relativeRank,
            errorMessage: parsed.errorMessage,
            warnings: parsed.warnings ?? [],
          })
        }
      } catch { /* Ignore malformed historical analysis rows. */ }
      }
    }
    const qualityGroups = new Map<string, Array<NonNullable<CullingAsset['quality']>>>()
    for (const [photoId, quality] of qualityByPhoto) {
      const groupId = similarityMap.get(photoId)
      if (!groupId || quality?.status !== 'succeeded') continue
      const group = qualityGroups.get(groupId) ?? []
      group.push(quality)
      qualityGroups.set(groupId, group)
    }
    for (const group of qualityGroups.values()) {
      group
        .sort((left, right) => right.score - left.score)
        .forEach((quality, index) => { quality.relativeRank = index + 1 })
    }
    const faceRows = this.db.prepare(`
      SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
      FROM face_observations
      WHERE session_id = ?
      ORDER BY id
    `).all(sessionId) as Array<{
      photo_id: string
      bbox_x: number
      bbox_y: number
      bbox_w: number
      bbox_h: number
      analysis_signature: string
    }>
    const facesByPhoto = new Map<string, number[][]>()
    const analysisMaxByPhoto = new Map<string, number>()
    for (const face of faceRows) {
      const list = facesByPhoto.get(face.photo_id) ?? []
      list.push([face.bbox_x, face.bbox_y, face.bbox_w, face.bbox_h])
      facesByPhoto.set(face.photo_id, list)
      if (!analysisMaxByPhoto.has(face.photo_id)) {
        try {
          const signature = JSON.parse(face.analysis_signature) as {
            previewMaxDimension?: unknown
          }
          if (
            typeof signature.previewMaxDimension === 'number' &&
            Number.isFinite(signature.previewMaxDimension)
          ) {
            analysisMaxByPhoto.set(face.photo_id, signature.previewMaxDimension)
          }
        } catch {
          // Older observations predate the persisted analysis signature.
        }
      }
    }
    const personRows = this.db.prepare(`
      SELECT pp.photo_id, p.name
      FROM person_photos pp
      JOIN persons p ON p.id = pp.person_id
      WHERE pp.session_id = ?
      ORDER BY p.name
    `).all(sessionId) as Array<{ photo_id: string; name: string }>
    const peopleByPhoto = new Map<string, string[]>()
    for (const person of personRows) {
      const names = peopleByPhoto.get(person.photo_id) ?? []
      if (!names.includes(person.name)) names.push(person.name)
      peopleByPhoto.set(person.photo_id, names)
    }
    const linkedCounts = new Map<string, number>()
    for (const photo of photos) {
      const xmpPath = getXmpSidecarPath(photo.filepath)
      linkedCounts.set(xmpPath, (linkedCounts.get(xmpPath) ?? 0) + 1)
    }

    const assets = photos.map((photo): CullingAsset => {
      const decision = decisions.get(photo.id)
      const cache = cacheRows.get(photo.id)
      const xmpPath = getXmpSidecarPath(photo.filepath)
      const outbox = outboxByPath.get(xmpPath)
      let metadataSource: MetadataMutationSource | undefined
      try {
        const parsed = JSON.parse(outbox?.patch_json ?? '{}') as { source?: unknown }
        if (
          typeof parsed.source === 'string' &&
          ['culling', 'face-keyword', 'similarity', 'template', 'manual'].includes(parsed.source)
        ) {
          metadataSource = parsed.source as MetadataMutationSource
        }
      } catch {
        // Historical invalid patches are surfaced by the sync status.
      }
      let keywords: string[] = []
      try {
        keywords = cache ? JSON.parse(cache.keywords) as string[] : []
      } catch {
        keywords = []
      }
      const sourceWidth = Math.max(1, photo.width ?? 1)
      const sourceHeight = Math.max(1, photo.height ?? 1)
      const analysisMax = analysisMaxByPhoto.get(photo.id)
        ?? Math.max(
          this.settings.getNumber('detect_input_size', 640),
          this.settings.getNumber('face_preview_max_dimension', 2048),
        )
      const analysisScale = Math.min(
        1,
        analysisMax / Math.max(sourceWidth, sourceHeight),
      )
      const analysisWidth = sourceWidth * analysisScale
      const analysisHeight = sourceHeight * analysisScale
      const normalizedFaces = (facesByPhoto.get(photo.id) ?? []).map(
        ([x, y, width, height]) => {
          // Current detector observations are already normalized. Older
          // databases stored preview-pixel coordinates, so retain a bounded
          // compatibility conversion for values outside the normalized range.
          const alreadyNormalized =
            x >= 0 && y >= 0 && width >= 0 && height >= 0 &&
            x <= 1 && y <= 1 && width <= 1 && height <= 1
          const values = alreadyNormalized
            ? [x, y, width, height]
            : [
                x / analysisWidth,
                y / analysisHeight,
                width / analysisWidth,
                height / analysisHeight,
              ]
          return values.map(value => Math.max(0, Math.min(1, value)))
        },
      ).sort((a, b) => (b[2] * b[3]) - (a[2] * a[3]))
      return {
        photo: photoRowToData(photo, facesByPhoto.get(photo.id)?.length ?? 0),
        state: this.rowToState(
          photo.id,
          decision,
          cache?.rating ?? 0,
          cache?.label ?? 'None',
        ),
        xmpPath,
        syncStatus: (outbox?.status ?? 'clean') as MetadataSyncStatus,
        people: peopleByPhoto.get(photo.id) ?? [],
        keywords,
        similarityGroupId: similarityMap.get(photo.id),
        linkedVariantCount: linkedCounts.get(xmpPath) ?? 1,
        faceBboxes: normalizedFaces,
        quality: qualityByPhoto.get(photo.id),
        metadataSource,
      }
    })

    const visibleAssets = [...new Map(
      assets.map(asset => [asset.photo.assetId ?? `photo:${asset.photo.id}`, asset]),
    ).values()].map(asset => {
      const variants = asset.photo.assetId
        ? assets.filter(candidate => candidate.photo.assetId === asset.photo.assetId)
        : [asset]
      const preferred = variants.find(candidate =>
        ['.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw']
          .some(extension => candidate.photo.filename.toLowerCase().endsWith(extension)),
      ) ?? variants[0]
      return {
        ...preferred,
        photo: {
          ...preferred.photo,
          variantCount: variants.length,
          variants: variants.map(variant => ({
            photoId: variant.photo.id,
            filepath: variant.photo.filepath,
            filename: variant.photo.filename,
            role: variant === preferred ? 'primary' : 'variant',
          })),
        },
      }
    })

    return visibleAssets.filter(asset => {
      if (scope === 'similarity_group') {
        if (!asset.similarityGroupId) return false
        if (requestedGroupId && asset.similarityGroupId !== requestedGroupId) return false
      }
      if (scope === 'filtered' && !this.matchesFilters(asset, filters)) return false
      return scope !== 'filtered' || this.matchesFilters(asset, filters)
    })
  }

  updateState(
    sessionId: string,
    photoId: string,
    expectedRevision: number,
    patch: CullingUpdatePatch,
    context?: {
      photos: PhotoRow[]
      groupMap: Map<string, string>
      photoById: Map<string, PhotoRow>
      linkedByXmp: Map<string, PhotoRow[]>
      historySink?: CullingHistoryEntry[]
    },
  ): CullingUpdateResult {
    this.validatePatch(patch)
    const photos = context?.photos ?? this.photoRepo.getBySession(sessionId)
    const target = context?.photoById.get(photoId)
      ?? photos.find(photo => photo.id === photoId)
    if (!target) throw new Error('Photo does not belong to this workspace')

    const currentRow = this.cullingDecisionRepo.getDecision(sessionId, photoId)
    const currentRevision = currentRow?.revision ?? 0
    if (currentRevision !== expectedRevision) {
      throw new Error(
        `Culling revision conflict: expected ${expectedRevision}, current ${currentRevision}`,
      )
    }

    const targetXmpPath = getXmpSidecarPath(target.filepath)
    const changesSharedMetadata =
      patch.rating !== undefined || patch.colorLabel !== undefined
    const affectedById = new Map<string, PhotoRow>()
    if (patch.pickState !== undefined && target.asset_id) {
      for (const photo of photos) {
        if (photo.asset_id === target.asset_id) affectedById.set(photo.id, photo)
      }
    } else {
      affectedById.set(target.id, target)
    }
    if (changesSharedMetadata) {
      for (const photo of context?.linkedByXmp.get(targetXmpPath)
        ?? photos.filter(photo => getXmpSidecarPath(photo.filepath) === targetXmpPath)) {
        affectedById.set(photo.id, photo)
      }
    }
    const affectedPhotos = [...affectedById.values()]
    const pickTargets = patch.pickState !== undefined && target.asset_id
      ? new Set(photos.filter(photo => photo.asset_id === target.asset_id).map(photo => photo.id))
      : new Set([target.id])
    const groupMap = context?.groupMap ?? this.buildPhotoGroupIndex(photos, sessionId)
    const resultStates: AssetCullingState[] = []
    const beforeStates: AssetCullingState[] = []
    let historyOperationId: number | undefined
    const metadataPatch: Record<string, unknown> = {}
    if (patch.rating !== undefined) metadataPatch.rating = patch.rating
    if (patch.colorLabel !== undefined) metadataPatch.label = patch.colorLabel === 'None' ? '' : patch.colorLabel

    this.db.transaction(() => {
      const existingRows = new Map(
        this.cullingDecisionRepo
          .getByPhotoIds(sessionId, affectedPhotos.map(photo => photo.id))
          .map(row => [row.photo_id, row]),
      )
      const cacheRows = new Map(
        this.metadataCacheRepo
          .getBatch(affectedPhotos.map(photo => photo.id))
          .map(row => [row.photo_id, row]),
      )

      for (const photo of affectedPhotos) {
        const existing = existingRows.get(photo.id)
        const cache = cacheRows.get(photo.id)
        const existingState = this.rowToState(
          photo.id,
          existing,
          cache?.rating ?? 0,
          cache?.label ?? 'None',
        )
        beforeStates.push(existingState)
        const isPickTarget = pickTargets.has(photo.id)
        const nextPickState = isPickTarget && patch.pickState !== undefined
          ? patch.pickState
          : existingState.pickState
        const nextRating = patch.rating ?? existingState.rating
        const nextColorLabel = patch.colorLabel ?? existingState.colorLabel
        const nextRevision = existingState.revision + 1

        this.cullingDecisionRepo.upsertState(
          sessionId,
          photo.id,
          groupMap.get(photo.id) ?? 'ungrouped',
          {
            decision: pickStateToDecision(nextPickState),
            rating: nextRating,
            colorLabel: nextColorLabel,
            revision: nextRevision,
          },
        )
        if (patch.rating !== undefined) {
          this.metadataCacheRepo.updateRating(photo.id, patch.rating)
        }
        if (patch.colorLabel !== undefined) {
          this.metadataCacheRepo.updateLabel(photo.id, patch.colorLabel)
        }
        resultStates.push({
          photoId: photo.id,
          pickState: nextPickState,
          rating: nextRating,
          colorLabel: nextColorLabel,
          source: 'manual',
          revision: nextRevision,
          updatedAt: new Date().toISOString(),
        })
      }

      const fields = Object.keys(patch) as Array<keyof CullingUpdatePatch>
      const historyEntries: CullingHistoryEntry[] = resultStates.map((after, index) => ({
        photoId: after.photoId,
        before: {
          pickState: beforeStates[index].pickState,
          rating: beforeStates[index].rating,
          colorLabel: beforeStates[index].colorLabel,
        },
        after: {
          pickState: after.pickState,
          rating: after.rating,
          colorLabel: after.colorLabel,
        },
        expectedRevision: after.revision,
        fields,
      }))
      if (Object.keys(metadataPatch).length > 0) {
        this.metadataMutations.queuePhotoValues(sessionId, photoId, metadataPatch, 'culling', false)
      }
      if (historyEntries.length > 0) {
        if (context?.historySink) context.historySink.push(...historyEntries)
        else historyOperationId = this.cullingHistoryRepo?.append(sessionId, historyEntries).id
      }
    })()

    if (Object.keys(metadataPatch).length > 0) this.metadataSync.schedule(targetXmpPath)

    const syncStatus = changesSharedMetadata
      ? this.metadataOutboxRepo.get(targetXmpPath)?.status ?? 'pending'
      : this.metadataOutboxRepo.get(targetXmpPath)?.status ?? 'clean'
    return {
      states: resultStates,
      xmpPath: targetXmpPath,
      syncStatus,
      historyOperationId,
    }
  }

  batchUpdate(
    sessionId: string,
    photoIds: string[],
    patch: CullingUpdatePatch,
  ): CullingUpdateResult[] {
    this.validatePatch(patch)
    const uniqueIds = [...new Set(photoIds)]
    if (uniqueIds.length === 0) throw new Error('请至少选择一张照片')
    const photos = this.photoRepo.getBySession(sessionId)
    const photoById = new Map(photos.map(photo => [photo.id, photo]))
    if (uniqueIds.some(photoId => !photoById.has(photoId))) {
      throw new Error('部分照片不属于当前工作区，请刷新后重试')
    }
    const groupMap = this.buildPhotoGroupIndex(photos, sessionId)
    const linkedByXmp = new Map<string, PhotoRow[]>()
    for (const photo of photos) {
      const xmpPath = getXmpSidecarPath(photo.filepath)
      const linked = linkedByXmp.get(xmpPath) ?? []
      linked.push(photo)
      linkedByXmp.set(xmpPath, linked)
    }
    const operationIds = patch.pickState === undefined
      ? [...new Map(
        uniqueIds.map(photoId => [
          getXmpSidecarPath(photoById.get(photoId)!.filepath),
          photoId,
        ] as const),
      ).values()]
      : [...new Map(
        uniqueIds.map(photoId => {
          const photo = photoById.get(photoId)!
          return [photo.asset_id ?? `photo:${photo.id}`, photoId] as const
        }),
      ).values()]
    const results: CullingUpdateResult[] = []
    const historyEntries: CullingHistoryEntry[] = []
    this.db.transaction(() => {
      for (const photoId of operationIds) {
        const current = this.cullingDecisionRepo.getDecision(sessionId, photoId)
        results.push(this.updateState(
          sessionId,
          photoId,
          current?.revision ?? 0,
          patch,
          { photos, groupMap, photoById, linkedByXmp, historySink: historyEntries },
        ))
      }
      if (historyEntries.length > 0) {
        const operationId = this.cullingHistoryRepo?.append(sessionId, historyEntries).id
        if (operationId !== undefined) {
          results.forEach(result => { result.historyOperationId = operationId })
        }
      }
    })()
    return results
  }

  applyHistory(
    sessionId: string,
    requestedEntries: CullingHistoryApplyEntry[],
    historyOperationId?: number,
    direction?: 'undo' | 'redo',
  ): CullingUpdateResult[] {
    let entries = requestedEntries
    let historicalFields = new Map<string, Array<keyof CullingUpdatePatch>>()
    if (historyOperationId !== undefined && direction) {
      const operation = this.cullingHistoryRepo?.get(sessionId, historyOperationId)
      if (!operation) throw new Error('挑片历史记录不存在')
      if (operation.undone !== (direction === 'redo')) {
        throw new Error(direction === 'undo' ? '该操作已撤销' : '该操作尚未撤销')
      }
      historicalFields = new Map(
        operation.entries.map(entry => [entry.photoId, entry.fields]),
      )
      entries = operation.entries.map(entry => ({
        photoId: entry.photoId,
        // The operation id and ordering are the concurrency guard. Revisions are
        // resolved from the current database state so consecutive undo/redo
        // remains valid after intervening history operations and app restarts.
        expectedRevision: -1,
        patch: Object.fromEntries(
          entry.fields.map(field => [
            field,
            (direction === 'undo' ? entry.before : entry.after)[field],
          ]),
        ) as CullingUpdatePatch,
      }))
    }
    if (entries.length === 0) return []
    const unique = new Set(entries.map(entry => entry.photoId))
    if (unique.size !== entries.length) throw new Error('History command contains duplicate photos')
    for (const entry of entries) this.validatePatch(entry.patch)
    const photos = this.photoRepo.getBySession(sessionId)
    const photoById = new Map(photos.map(photo => [photo.id, photo]))
    const groupMap = this.buildPhotoGroupIndex(photos, sessionId)
    const currentRows = new Map(
      this.cullingDecisionRepo.getByPhotoIds(sessionId, entries.map(entry => entry.photoId))
        .map(row => [row.photo_id, row]),
    )
    const cacheRows = new Map(
      this.metadataCacheRepo.getBatch(entries.map(entry => entry.photoId))
        .map(row => [row.photo_id, row]),
    )
    for (const entry of entries) {
      if (!photoById.has(entry.photoId)) throw new Error('Photo does not belong to this workspace')
      const currentRevision = currentRows.get(entry.photoId)?.revision ?? 0
      if (historyOperationId === undefined && currentRevision !== entry.expectedRevision) {
        throw new Error(
          `Culling revision conflict: expected ${entry.expectedRevision}, current ${currentRevision}`,
        )
      }
    }
    if (historyOperationId !== undefined && direction) {
      const operation = this.cullingHistoryRepo?.get(sessionId, historyOperationId)
      for (const historical of operation?.entries ?? []) {
        const row = currentRows.get(historical.photoId)
        const cache = cacheRows.get(historical.photoId)
        const current = this.rowToState(
          historical.photoId,
          row,
          cache?.rating ?? 0,
          cache?.label ?? 'None',
        )
        const expected = direction === 'undo' ? historical.after : historical.before
        for (const field of historical.fields) {
          if (current[field] !== expected[field]) {
            throw new Error('挑片状态已在历史记录之外发生变化，请刷新后重试')
          }
        }
      }
    }

    const results: CullingUpdateResult[] = []
    const historyEntries: CullingHistoryEntry[] = []
    const xmpPatches = new Map<string, {
      photoId: string
      values: Record<string, unknown>
    }>()
    this.db.transaction(() => {
      for (const entry of entries) {
        const photo = photoById.get(entry.photoId)!
        const existing = currentRows.get(entry.photoId)
        const cache = cacheRows.get(entry.photoId)
        const before = this.rowToState(
          entry.photoId,
          existing,
          cache?.rating ?? 0,
          cache?.label ?? 'None',
        )
        const after: AssetCullingState = {
          photoId: entry.photoId,
          pickState: entry.patch.pickState ?? before.pickState,
          rating: entry.patch.rating ?? before.rating,
          colorLabel: entry.patch.colorLabel ?? before.colorLabel,
          source: 'manual',
          revision: before.revision + 1,
          updatedAt: new Date().toISOString(),
        }
        this.cullingDecisionRepo.upsertState(
          sessionId,
          entry.photoId,
          groupMap.get(entry.photoId) ?? 'ungrouped',
          {
            decision: pickStateToDecision(after.pickState),
            rating: after.rating,
            colorLabel: after.colorLabel,
            revision: after.revision,
          },
        )
        if (entry.patch.rating !== undefined) this.metadataCacheRepo.updateRating(entry.photoId, after.rating)
        if (entry.patch.colorLabel !== undefined) this.metadataCacheRepo.updateLabel(entry.photoId, after.colorLabel)
        const xmpPath = getXmpSidecarPath(photo.filepath)
        const values = xmpPatches.get(xmpPath)?.values ?? {}
        if (entry.patch.rating !== undefined) values.rating = after.rating
        if (entry.patch.colorLabel !== undefined) {
          values.label = after.colorLabel === 'None' ? '' : after.colorLabel
        }
        if (Object.keys(values).length > 0) {
          xmpPatches.set(xmpPath, { photoId: entry.photoId, values })
        }
        historyEntries.push({
          photoId: entry.photoId,
          before: {
            pickState: before.pickState,
            rating: before.rating,
            colorLabel: before.colorLabel,
          },
          after: {
            pickState: after.pickState,
            rating: after.rating,
            colorLabel: after.colorLabel,
          },
          expectedRevision: after.revision,
          fields: historicalFields.get(entry.photoId)
            ?? Object.keys(entry.patch) as Array<keyof CullingUpdatePatch>,
        })
        results.push({
          states: [after],
          xmpPath,
          syncStatus: this.metadataOutboxRepo.get(xmpPath)?.status ?? 'clean',
        })
      }
      for (const { photoId, values } of xmpPatches.values()) {
        this.metadataMutations.queuePhotoValues(sessionId, photoId, values, 'culling', false)
      }
      if (historyOperationId !== undefined && direction) {
        this.cullingHistoryRepo?.setUndone(
          sessionId,
          historyOperationId,
          direction === 'undo',
        )
      } else {
        historyOperationId = this.cullingHistoryRepo?.append(sessionId, historyEntries).id
      }
    })()
    for (const xmpPath of xmpPatches.keys()) this.metadataSync.schedule(xmpPath)
    return results.map(result => ({
      ...result,
      syncStatus: this.metadataOutboxRepo.get(result.xmpPath)?.status ?? result.syncStatus,
      historyOperationId,
    }))
  }

  decideSimilarityGroup(
    sessionId: string,
    groupId: string,
    keepPhotoIds: string[],
  ): CullingUpdateResult[] {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) throw new Error('尚无相似度分析结果')
    const membership = this.similarityResultRepo.getPhotoGroupMap(sessionId, resultRow.id)
    const groupPhotoIds = [...membership.entries()]
      .filter(([, candidateGroupId]) => candidateGroupId === groupId)
      .map(([photoId]) => photoId)
    if (groupPhotoIds.length < 2) throw new Error('相似组不存在或成员不足')

    const keepIds = [...new Set(keepPhotoIds)]
    const groupIdSet = new Set(groupPhotoIds)
    if (
      keepIds.length < 1 ||
      keepIds.length >= groupPhotoIds.length ||
      keepIds.some(photoId => !groupIdSet.has(photoId))
    ) {
      throw new Error('保留照片必须来自当前相似组，且至少淘汰一张')
    }
    const keepIdSet = new Set(keepIds)
    const currentRows = new Map(
      this.cullingDecisionRepo.getByPhotoIds(sessionId, groupPhotoIds)
        .map(row => [row.photo_id, row]),
    )
    return this.applyHistory(
      sessionId,
      groupPhotoIds.map(photoId => ({
        photoId,
        expectedRevision: currentRows.get(photoId)?.revision ?? 0,
        patch: { pickState: keepIdSet.has(photoId) ? 'picked' : 'rejected' },
      })),
    )
  }

  getGroups(sessionId: string): CullingGroup[] {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) return []

    const photos = this.photoRepo.getBySession(sessionId)
    const photoById = new Map(photos.map(photo => [photo.id, photo]))
    const membership = this.similarityResultRepo.getPhotoGroupMap(sessionId, resultRow.id)
    const membersByGroup = new Map<string, string[]>()
    for (const photo of photos) {
      const groupId = membership.get(photo.id)
      if (!groupId) continue
      const members = membersByGroup.get(groupId) ?? []
      members.push(photo.id)
      membersByGroup.set(groupId, members)
    }
    const decisions = new Map(
      this.cullingDecisionRepo.getBySession(sessionId)
        .map(row => [row.photo_id, row.decision]),
    )

    return [...membersByGroup.entries()].map(([groupId, photoIds]) => {
      const groupIndex = Number(groupId.split(':').at(-1))
      let keepCount = 0
      let rejectCount = 0
      let pendingCount = 0
      const images = photoIds.flatMap((photoId): CullingImage[] => {
        const photo = photoById.get(photoId)
        if (!photo) return []
        const decision = (decisions.get(photoId) ?? 'pending') as
          LegacyCullingDecision
        if (decision === 'keep') keepCount++
        else if (decision === 'reject') rejectCount++
        else pendingCount++
        return [{
          photoId,
          filepath: photo.filepath,
          filename: photo.filename,
          decision,
        }]
      })
      return { groupId, groupIndex, images, keepCount, rejectCount, pendingCount }
    }).sort((left, right) => left.groupIndex - right.groupIndex)
  }

  decide(sessionId: string, photoId: string, decision: string): void {
    const current = this.cullingDecisionRepo.getDecision(sessionId, photoId)
    this.updateState(
      sessionId,
      photoId,
      current?.revision ?? 0,
      { pickState: decisionToPickState(decision) },
    )
  }

  batchDecide(sessionId: string, photoIds: string[], decision: string): void {
    this.batchUpdate(sessionId, photoIds, {
      pickState: decisionToPickState(decision),
    })
  }

  getDecisions(sessionId: string): { photo_id: string; decision: string }[] {
    return this.cullingDecisionRepo.getDecisions(sessionId)
  }

  getHistory(sessionId: string, limit?: number) {
    return this.cullingHistoryRepo?.list(sessionId, limit) ?? []
  }

  getSummary(sessionId: string): CullingSummary {
    const photos = this.photoRepo.getBySession(sessionId)
    const decisions = this.cullingDecisionRepo.getBySession(sessionId)
    const decisionByPhoto = new Map(decisions.map(row => [row.photo_id, row]))
    const cacheByPhoto = new Map(
      this.metadataCacheRepo.getBatch(photos.map(photo => photo.id))
        .map(row => [row.photo_id, row]),
    )
    let kept = 0
    let rejected = 0
    let rated = 0
    let labeled = 0
    for (const photo of photos) {
      const row = decisionByPhoto.get(photo.id)
      const cache = cacheByPhoto.get(photo.id)
      if (row?.decision === 'keep') kept++
      if (row?.decision === 'reject') rejected++
      if ((row?.rating ?? cache?.rating ?? 0) > 0) rated++
      const label = row?.color_label ?? cache?.label ?? 'None'
      if (COLOR_LABELS.has(label as CaptureOneColorLabel) && label !== 'None') {
        labeled++
      }
    }
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    let totalGroups = 0
    if (resultRow) {
      const parsed = JSON.parse(resultRow.groups_json) as { groups?: unknown[] }
      totalGroups = parsed.groups?.length ?? 0
    }
    return {
      totalGroups,
      totalPhotos: photos.length,
      kept,
      rejected,
      pending: Math.max(0, photos.length - kept - rejected),
      rated,
      labeled,
    }
  }

  reset(sessionId: string, groupId?: string): void {
    if (groupId) this.cullingDecisionRepo.deleteBySessionAndGroup(sessionId, groupId)
    else this.cullingDecisionRepo.deleteBySession(sessionId)
  }

  private validatePatch(patch: CullingUpdatePatch): void {
    if (
      patch.rating === undefined &&
      patch.pickState === undefined &&
      patch.colorLabel === undefined
    ) {
      throw new Error('Culling patch cannot be empty')
    }
    if (
      patch.rating !== undefined &&
      (!Number.isInteger(patch.rating) || patch.rating < 0 || patch.rating > 5)
    ) {
      throw new Error('rating must be an integer from 0 to 5')
    }
    if (
      patch.pickState !== undefined &&
      !['unreviewed', 'picked', 'rejected'].includes(patch.pickState)
    ) {
      throw new Error('Invalid pickState')
    }
    if (
      patch.colorLabel !== undefined &&
      !COLOR_LABELS.has(patch.colorLabel)
    ) {
      throw new Error('Invalid colorLabel')
    }
  }

  private rowToState(
    photoId: string,
    row: CullingDecisionRow | undefined,
    fallbackRating: number,
    fallbackLabel: string,
  ): AssetCullingState {
    const colorLabel = COLOR_LABELS.has(fallbackLabel as CaptureOneColorLabel)
      ? fallbackLabel as CaptureOneColorLabel
      : 'None'
    const rating = Number.isInteger(fallbackRating) &&
      fallbackRating >= 0 &&
      fallbackRating <= 5
      ? fallbackRating
      : 0
    return {
      photoId,
      pickState: decisionToPickState(row?.decision),
      rating: row?.rating ?? rating,
      colorLabel: row
        ? COLOR_LABELS.has(row.color_label as CaptureOneColorLabel)
          ? row.color_label as CaptureOneColorLabel
          : 'None'
        : colorLabel,
      source: row
        ? ['manual', 'ai', 'template', 'imported'].includes(row.decision_source)
          ? row.decision_source as AssetCullingState['source']
          : 'manual'
        : 'imported',
      revision: row?.revision ?? 0,
      updatedAt: row?.updated_at ?? '',
    }
  }

  private getLatestSimilarityMap(sessionId: string): Map<string, string> {
    const result = this.similarityResultRepo.getLatest(sessionId)
    if (!result) return new Map()
    return this.similarityResultRepo.getPhotoGroupMap(sessionId, result.id)
  }

  private buildPhotoGroupIndex(
    photos: Array<{ id: string; filepath: string }>,
    sessionId: string,
  ): Map<string, string> {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) return new Map()
    const persisted = this.similarityResultRepo.getPhotoGroupMap(sessionId, resultRow.id)
    if (persisted.size > 0) return persisted

    const parsed = JSON.parse(resultRow.groups_json) as { groups: SimilarityGroup[] }
    const photoIdByPath = new Map(photos.map(photo => [photo.filepath, photo.id]))
    const groupByPhotoId = new Map<string, string>()
    for (let index = 0; index < (parsed.groups ?? []).length; index++) {
      for (const image of parsed.groups[index].images) {
        const photoId = photoIdByPath.get(image.path)
        if (photoId) groupByPhotoId.set(photoId, `${resultRow.id}:${index}`)
      }
    }
    return groupByPhotoId
  }

  private matchesFilters(asset: CullingAsset, filters?: CullingFilters): boolean {
    if (!filters) return true
    if (filters.unreviewedOnly && asset.state.pickState !== 'unreviewed') return false
    if (filters.ratings?.length && !filters.ratings.includes(asset.state.rating)) return false
    if (
      filters.pickStates?.length &&
      !filters.pickStates.includes(asset.state.pickState)
    ) return false
    if (
      filters.colorLabels?.length &&
      !filters.colorLabels.includes(asset.state.colorLabel)
    ) return false
    if (filters.qualityStatus === 'analysed' && asset.quality?.status !== 'succeeded') return false
    if (filters.qualityStatus === 'failed' && asset.quality?.status !== 'failed') return false
    if (filters.qualityStatus === 'unanalysed' && asset.quality !== undefined) return false
    if (filters.metadataConflictOnly && asset.syncStatus !== 'conflict') return false
    return true
  }
}
