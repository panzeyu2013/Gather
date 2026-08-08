import type {
  SimilarityGroup,
  SimilarityKeywordAssignment,
  WritebackAttributes,
} from '@gather/shared'
import type { FaceClusterRow } from '../../db/repositories/face.repo'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'

export function buildCullingWritebackPlan(
  decisions: Array<{ photo_id: string; decision: string }>,
  target: 'rating' | 'color_label' | 'keyword',
): Map<string, WritebackAttributes> {
  const plan = new Map<string, WritebackAttributes>()
  for (const item of decisions) {
    if (item.decision === 'pending') continue
    if (target === 'rating') {
      plan.set(item.photo_id, { rating: item.decision === 'keep' ? 5 : 1 })
    } else if (target === 'color_label') {
      plan.set(item.photo_id, { label: item.decision === 'keep' ? 'Green' : 'Red' })
    } else {
      plan.set(item.photo_id, { keywords: [`culling:${item.decision}`] })
    }
  }
  return plan
}

export function buildSimilarityKeywordPlan(
  groups: SimilarityGroup[],
  assignments: SimilarityKeywordAssignment[],
): { keywordsBySidecar: Map<string, string[]>; affectedPaths: Set<string> } {
  const groupsById = new Map(groups.map(group => [group.id, group]))
  const keywordsBySidecar = new Map<string, string[]>()
  const affectedPaths = new Set<string>()
  for (const assignment of assignments) {
    const group = groupsById.get(assignment.groupId)
    if (!group) throw new Error('WRITEBACK_GROUP_NOT_IN_SESSION')
    for (const image of group.images) {
      affectedPaths.add(image.path)
      const sidecarPath = getXmpSidecarPath(image.path)
      keywordsBySidecar.set(sidecarPath, [
        ...new Set([...(keywordsBySidecar.get(sidecarPath) ?? []), ...assignment.keywords]),
      ])
    }
  }
  return { keywordsBySidecar, affectedPaths }
}

export function buildFaceKeywordAdditions(
  clusters: FaceClusterRow[],
): Map<string, string[]> {
  const additions = new Map<string, string[]>()
  for (const cluster of clusters) {
    if (!cluster.binding) continue
    const keywords = [...new Set(
      [cluster.binding.roleName, ...cluster.binding.keywords]
        .map(keyword => keyword.trim())
        .filter(Boolean),
    )]
    for (const member of cluster.members ?? []) {
      additions.set(member.photo_id, [
        ...new Set([...(additions.get(member.photo_id) ?? []), ...keywords]),
      ])
    }
  }
  return additions
}
