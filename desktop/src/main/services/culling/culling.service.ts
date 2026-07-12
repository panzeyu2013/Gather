import { getDatabase } from '../../db/database'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { CullingDecisionRepository } from '../../db/repositories/culling-decision.repo'
import { SimilarityResultRepository } from '../../db/repositories/similarity-result.repo'
import type { CullingGroup, CullingImage, CullingSummary, SimilarityGroup, SimilarityImage } from '@gather/shared'

export class CullingService {
  constructor(
    private photoRepo: PhotoRepository,
    private cullingDecisionRepo: CullingDecisionRepository,
    private similarityResultRepo: SimilarityResultRepository,
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

  private findGroupId(photos: { id: string; filepath: string }[], sessionId: string, photoId: string): string | null {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)

    if (!resultRow) return null

    const parsed = JSON.parse(resultRow.groups_json) as { groups: SimilarityGroup[] }
    const groups = parsed.groups ?? []

    const photo = photos.find((p) => p.id === photoId)
    if (!photo) return null

    for (let i = 0; i < groups.length; i++) {
      const found = groups[i].images.some((img) => img.path === photo.filepath)
      if (found) {
        return `${resultRow.id}:${i}`
      }
    }

    return null
  }

  decide(sessionId: string, photoId: string, decision: string): void {
    const photos = this.photoRepo.getBySession(sessionId)
    const groupId = this.findGroupId(photos, sessionId, photoId) ?? 'ungrouped'
    this.cullingDecisionRepo.upsert(sessionId, photoId, groupId, decision)
  }

  batchDecide(sessionId: string, photoIds: string[], decision: string): void {
    const db = getDatabase()
    const photos = this.photoRepo.getBySession(sessionId)

    const batch = db.transaction(() => {
      for (const photoId of photoIds) {
        const groupId = this.findGroupId(photos, sessionId, photoId) ?? 'ungrouped'
        this.cullingDecisionRepo.upsert(sessionId, photoId, groupId, decision)
      }
    })

    batch()
  }

  getDecisions(sessionId: string): { photo_id: string; decision: string }[] {
    return this.cullingDecisionRepo.getDecisions(sessionId)
  }

  getSummary(sessionId: string): CullingSummary {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)

    const groups: SimilarityGroup[] = resultRow
      ? (JSON.parse(resultRow.groups_json) as { groups: SimilarityGroup[] }).groups ?? []
      : []

    const totalPhotos = groups.reduce((sum, g) => sum + g.images.length, 0)

    const counts = this.cullingDecisionRepo.getDecisionCounts(sessionId)

    let kept = 0
    let rejected = 0
    for (const row of counts) {
      if (row.decision === 'keep') kept = row.cnt
      else if (row.decision === 'reject') rejected = row.cnt
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
