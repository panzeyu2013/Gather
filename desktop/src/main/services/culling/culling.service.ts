import { PhotoRepository } from '../../db/repositories/photo.repo'
import { CullingDecisionRepository } from '../../db/repositories/culling-decision.repo'
import { SimilarityResultRepository } from '../../db/repositories/similarity-result.repo'
import type { CullingGroup, CullingImage, CullingSummary, SimilarityGroup, SimilarityImage } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

@injectable()
export class CullingService {
  constructor(
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.CULLING_DECISION_REPO) private cullingDecisionRepo: CullingDecisionRepository,
    @inject(DI_TOKENS.SIMILARITY_RESULT_REPO) private similarityResultRepo: SimilarityResultRepository,
  ) {}

  getGroups(sessionId: string): CullingGroup[] {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)

    if (!resultRow) {
      return []
    }

    const parsed = JSON.parse(resultRow.groups_json) as { groups: SimilarityGroup[]; ungrouped: SimilarityImage[] }
    const groups: SimilarityGroup[] = parsed.groups ?? []

    const photos = this.photoRepo.getBySession(sessionId)
    const pathToPhoto = new Map(photos.map((p) => [p.filepath, p]))

    const decisions = this.cullingDecisionRepo.getBySession(sessionId)
    const decisionMap = new Map<string, string>()
    for (const d of decisions) {
      decisionMap.set(`${d.group_id}:${d.photo_id}`, d.decision)
    }

    return groups.map((group, index) => {
      const groupId = `${resultRow.id}:${index}`
      let keepCount = 0
      let rejectCount = 0
      let pendingCount = 0

      const images: CullingImage[] = group.images.map((img) => {
        const photo = pathToPhoto.get(img.path)
        const photoId = photo?.id ?? ''
        const filename = photo?.filename ?? (img.path.split(/[/\\]/).pop() ?? img.path)
        const decisionKey = `${groupId}:${photoId}`
        const decision = (decisionMap.get(decisionKey) ?? 'pending') as CullingImage['decision']

        if (decision === 'keep') keepCount++
        else if (decision === 'reject') rejectCount++
        else pendingCount++

        return {
          photoId,
          filepath: img.path,
          filename,
          decision,
        }
      })

      return {
        groupId,
        groupIndex: index,
        images,
        keepCount,
        rejectCount,
        pendingCount,
      }
    })
  }

  private buildPhotoGroupIndex(
    photos: { id: string; filepath: string }[],
    sessionId: string,
  ): Map<string, string> {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) return new Map()
    const persisted = this.similarityResultRepo.getPhotoGroupMap(sessionId, resultRow.id)
    if (persisted.size > 0) return persisted

    // Compatibility fallback for results produced before schema version 10.
    const parsed = JSON.parse(resultRow.groups_json) as { groups: SimilarityGroup[] }
    const groups = parsed.groups ?? []
    const photoIdByPath = new Map(photos.map(photo => [photo.filepath, photo.id]))
    const groupByPhotoId = new Map<string, string>()
    for (let i = 0; i < groups.length; i++) {
      const groupId = `${resultRow.id}:${i}`
      for (const image of groups[i].images) {
        const photoId = photoIdByPath.get(image.path)
        if (photoId) groupByPhotoId.set(photoId, groupId)
      }
    }
    return groupByPhotoId
  }

  decide(sessionId: string, photoId: string, decision: string): void {
    const photos = this.photoRepo.getBySession(sessionId)
    const groupId = this.buildPhotoGroupIndex(photos, sessionId).get(photoId) ?? 'ungrouped'
    this.cullingDecisionRepo.upsert(sessionId, photoId, groupId, decision)
  }

  batchDecide(sessionId: string, photoIds: string[], decision: string): void {
    const photos = this.photoRepo.getBySession(sessionId)
    const groupByPhotoId = this.buildPhotoGroupIndex(photos, sessionId)

    this.cullingDecisionRepo.upsertMany(
      sessionId,
      photoIds.map(photoId => ({
        photoId,
        groupId: groupByPhotoId.get(photoId) ?? 'ungrouped',
        decision,
      })),
    )
  }

  getDecisions(sessionId: string): { photo_id: string; decision: string }[] {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) return []
    return this.cullingDecisionRepo.getByResultPrefix(sessionId, resultRow.id)
  }

  getSummary(sessionId: string): CullingSummary {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)

    const groups: SimilarityGroup[] = resultRow
      ? (JSON.parse(resultRow.groups_json) as { groups: SimilarityGroup[] }).groups ?? []
      : []

    const totalPhotos = groups.reduce((sum, g) => sum + g.images.length, 0)

    let kept = 0
    let rejected = 0
    if (resultRow) {
      const counts = this.cullingDecisionRepo.getCountsByResultPrefix(sessionId, resultRow.id)
      for (const row of counts) {
        if (row.decision === 'keep') kept = row.cnt
        else if (row.decision === 'reject') rejected = row.cnt
      }
    }
    const pending = totalPhotos - kept - rejected

    return {
      totalGroups: groups.length,
      totalPhotos,
      kept,
      rejected,
      pending: Math.max(0, pending),
    }
  }

  reset(sessionId: string, groupId?: string): void {
    if (groupId) {
      this.cullingDecisionRepo.deleteBySessionAndGroup(sessionId, groupId)
    } else {
      this.cullingDecisionRepo.deleteBySession(sessionId)
    }
  }
}
