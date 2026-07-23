import { getService } from '../../di/init'
import { DI_TOKENS } from '../../di/container'
import type { FaceRepository } from '../../db/repositories/face.repo'
import type { CullingDecisionRepository } from '../../db/repositories/culling-decision.repo'
import type { Database } from '../../db/database'

function faceRepo(): FaceRepository {
  return getService<FaceRepository>(DI_TOKENS.FACE_REPO)
}

function cullingRepo(): CullingDecisionRepository {
  return getService<CullingDecisionRepository>(DI_TOKENS.CULLING_DECISION_REPO)
}

function db(): Database {
  return getService<Database>(DI_TOKENS.DB)
}

export type UndoHandlerMap = Record<string, (params: Record<string, unknown>, snapshotBefore: Record<string, unknown>) => void>

export const undoHandlers: UndoHandlerMap = {
  face_bind: (_params, before) => {
    const clusterId = before.cluster_id as number
    if (clusterId) {
      faceRepo().deleteBinding(clusterId)
    }
  },

  face_unbind: (_params, before) => {
    const clusterId = before.cluster_id as number
    const roleName = before.role_name as string
    const keywords = before.keywords as string[]
    if (clusterId && roleName && keywords) {
      faceRepo().restoreBinding(clusterId, before.session_id as string, roleName, keywords)
    }
  },

  face_merge: (_params, before) => {
    const sourceClusterId = before.source_cluster_id as number
    const targetClusterId = before.target_cluster_id as number
    const sourceMemberIds = (before.source_member_ids as number[]) ?? []
    const sourceMemberCount = (before.source_member_count as number) ?? 0
    const sourceBinding = before.source_binding as { clusterId: string; roleName: string; keywords: string[] } | undefined

    if (!sourceClusterId || !targetClusterId || sourceMemberIds.length === 0) return

    faceRepo().restoreMerge(
      sourceClusterId,
      targetClusterId,
      before.session_id as string,
      sourceMemberIds,
      sourceMemberCount,
      sourceBinding,
    )
  },

  culling_batch: (_params, before) => {
    const decisions = before.decisions as Array<{ photo_id: string; session_id: string; decision: string }> | undefined
    if (!decisions || decisions.length === 0) return
    cullingRepo().batchRestoreDecisions(decisions)
  },

  dup_resolve: (_params, before) => {
    const members = before.members as Array<{ id: number; is_kept: number }> | undefined
    if (!members || members.length === 0) return

    const d = db()
    const groupId = before.group_id as number
    const restoreTransaction = d.transaction(() => {
      for (const m of members) {
        d.prepare('UPDATE duplicate_group_members SET is_kept = ? WHERE id = ?').run(m.is_kept, m.id)
      }
      if (groupId) {
        d.prepare('UPDATE duplicate_groups SET resolution = NULL WHERE id = ?').run(groupId)
      }
    })
    restoreTransaction()
  },

  template_apply: (_params, before) => {
    const sessionId = before.session_id as string
    const config = before.config as Record<string, unknown> | undefined
    if (!sessionId || !config) return

    const d = db()
    d.prepare('UPDATE sessions SET analysis_status = ? WHERE id = ?').run(
      (config.analysis_status as string) ?? 'idle',
      sessionId,
    )
  },
}
