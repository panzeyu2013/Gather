import { PhotoRepository, type PhotoRow } from '../../db/repositories/photo.repo'
import {
  CullingDecisionRepository,
  type CullingDecisionRow,
} from '../../db/repositories/culling-decision.repo'
import { SimilarityResultRepository } from '../../db/repositories/similarity-result.repo'
import { MetadataCacheRepository } from '../../db/repositories/metadata-cache.repo'
import { MetadataOutboxRepository } from '../../db/repositories/metadata-outbox.repo'
import { Database } from '../../db/database'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'
import { MetadataSyncCoordinator } from '../metadata/metadata-sync-coordinator'
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
  LegacyCullingDecision,
  MetadataSyncStatus,
  PhotoData,
  PickState,
  SimilarityGroup,
  SimilarityImage,
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
    @inject(DI_TOKENS.SETTINGS_SERVICE)
    private settings: SettingsService,
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
        ([x, y, width, height]) => [
          x / analysisWidth,
          y / analysisHeight,
          width / analysisWidth,
          height / analysisHeight,
        ],
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
        syncStatus: (outboxByPath.get(xmpPath)?.status ?? 'clean') as MetadataSyncStatus,
        people: peopleByPhoto.get(photo.id) ?? [],
        keywords,
        similarityGroupId: similarityMap.get(photo.id),
        linkedVariantCount: linkedCounts.get(xmpPath) ?? 1,
        faceBboxes: normalizedFaces,
      }
    })

    return assets.filter(asset => {
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
    const affectedPhotos = changesSharedMetadata
      ? context?.linkedByXmp.get(targetXmpPath)
        ?? photos.filter(photo => getXmpSidecarPath(photo.filepath) === targetXmpPath)
      : [target]
    const groupMap = context?.groupMap ?? this.buildPhotoGroupIndex(photos, sessionId)
    const resultStates: AssetCullingState[] = []

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
        const isTarget = photo.id === photoId
        const nextPickState = isTarget && patch.pickState !== undefined
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
          revision: nextRevision,
          updatedAt: new Date().toISOString(),
        })
      }

      const metadataPatch: Record<string, unknown> = {}
      const dirtyFields: string[] = []
      if (patch.rating !== undefined) {
        metadataPatch.rating = patch.rating
        dirtyFields.push('rating')
      }
      if (patch.colorLabel !== undefined) {
        metadataPatch.label = patch.colorLabel === 'None' ? '' : patch.colorLabel
        dirtyFields.push('label')
      }
      if (dirtyFields.length > 0) {
        this.metadataOutboxRepo.mergePatch(
          targetXmpPath,
          sessionId,
          target.filepath,
          metadataPatch,
          dirtyFields,
        )
      }
    })()

    const syncStatus = changesSharedMetadata
      ? this.metadataOutboxRepo.get(targetXmpPath)?.status ?? 'pending'
      : this.metadataOutboxRepo.get(targetXmpPath)?.status ?? 'clean'
    if (changesSharedMetadata) this.metadataSync.schedule(targetXmpPath)

    return {
      states: resultStates,
      xmpPath: targetXmpPath,
      syncStatus,
    }
  }

  batchUpdate(
    sessionId: string,
    photoIds: string[],
    patch: CullingUpdatePatch,
  ): CullingUpdateResult[] {
    this.validatePatch(patch)
    const uniqueIds = [...new Set(photoIds)]
    const photos = this.photoRepo.getBySession(sessionId)
    const groupMap = this.buildPhotoGroupIndex(photos, sessionId)
    const photoById = new Map(photos.map(photo => [photo.id, photo]))
    const linkedByXmp = new Map<string, PhotoRow[]>()
    for (const photo of photos) {
      const xmpPath = getXmpSidecarPath(photo.filepath)
      const linked = linkedByXmp.get(xmpPath) ?? []
      linked.push(photo)
      linkedByXmp.set(xmpPath, linked)
    }
    const operationIds = patch.pickState === undefined
      ? [...new Map(
        uniqueIds.flatMap(photoId => {
          const photo = photoById.get(photoId)
          return photo
            ? [[getXmpSidecarPath(photo.filepath), photoId] as const]
            : []
        }),
      ).values()]
      : uniqueIds
    const results: CullingUpdateResult[] = []
    this.db.transaction(() => {
      for (const photoId of operationIds) {
        const current = this.cullingDecisionRepo.getDecision(sessionId, photoId)
        results.push(this.updateState(
          sessionId,
          photoId,
          current?.revision ?? 0,
          patch,
          { photos, groupMap, photoById, linkedByXmp },
        ))
      }
    })()
    return results
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
    const rejectIds = groupPhotoIds.filter(photoId => !keepIdSet.has(photoId))

    return this.db.transaction(() => [
      ...this.batchUpdate(sessionId, keepIds, { pickState: 'picked' }),
      ...this.batchUpdate(sessionId, rejectIds, { pickState: 'rejected' }),
    ])()
  }

  getGroups(sessionId: string): CullingGroup[] {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) return []

    const parsed = JSON.parse(resultRow.groups_json) as {
      groups: SimilarityGroup[]
      ungrouped: SimilarityImage[]
    }
    const groups: SimilarityGroup[] = parsed.groups ?? []
    const photos = this.photoRepo.getBySession(sessionId)
    const pathToPhoto = new Map(photos.map(photo => [photo.filepath, photo]))
    const decisions = new Map(
      this.cullingDecisionRepo.getBySession(sessionId)
        .map(row => [`${row.group_id}:${row.photo_id}`, row.decision]),
    )

    return groups.map((group, index) => {
      const groupId = `${resultRow.id}:${index}`
      let keepCount = 0
      let rejectCount = 0
      let pendingCount = 0
      const images = group.images.map((image): CullingImage => {
        const photo = pathToPhoto.get(image.path)
        const photoId = photo?.id ?? ''
        const decision = (decisions.get(`${groupId}:${photoId}`) ?? 'pending') as
          LegacyCullingDecision
        if (decision === 'keep') keepCount++
        else if (decision === 'reject') rejectCount++
        else pendingCount++
        return {
          photoId,
          filepath: image.path,
          filename: photo?.filename ?? image.path.split(/[/\\]/).pop() ?? image.path,
          decision,
        }
      })
      return { groupId, groupIndex: index, images, keepCount, rejectCount, pendingCount }
    })
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
    return true
  }
}
