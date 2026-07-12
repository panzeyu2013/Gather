import { getDatabase } from '../../db/database'
import { FaceRepository } from '../../db/repositories/face.repo'

const faceRepo = new FaceRepository()

export type UndoHandlerMap = Record<string, (params: Record<string, unknown>, snapshotBefore: Record<string, unknown>) => void>

export const undoHandlers: UndoHandlerMap = {
  face_bind: (_params, before) => {
    const clusterId = before.cluster_id as number
    if (clusterId) {
      faceRepo.deleteBinding(clusterId)
    }
  },

  face_unbind: (_params, before) => {
    const clusterId = before.cluster_id as number
    const roleName = before.role_name as string
    const keywords = before.keywords as string[]
    const db = getDatabase()
    if (clusterId && roleName && keywords) {
      const unbindTransaction = db.transaction(() => {
        db.prepare(
          'INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)',
        ).run(clusterId, before.session_id as string, roleName, JSON.stringify(keywords))
        db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(clusterId)
      })
      unbindTransaction()
    }
  },

  face_merge: (_params, before) => {
    const sourceClusterId = before.source_cluster_id as number
    const targetClusterId = before.target_cluster_id as number

    if (!sourceClusterId || !targetClusterId) return

    const db = getDatabase()

    const sourceMembers = db
      .prepare('SELECT * FROM face_cluster_members WHERE cluster_id = ?')
      .all(targetClusterId) as { id: number; photo_id: string }[]

    const restoreTransaction = db.transaction(() => {
      for (const member of sourceMembers) {
        const isOriginalSourceMember = (before.source_member_ids as number[] | undefined)?.includes(member.id)
        if (isOriginalSourceMember) {
          db.prepare('UPDATE face_cluster_members SET cluster_id = ? WHERE id = ?').run(sourceClusterId, member.id)
        }
      }

      const sourceCount = db
        .prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?')
        .get(sourceClusterId) as { count: number }

      const targetCount = db
        .prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?')
        .get(targetClusterId) as { count: number }

      const originalMemberCount = (before.source_member_count as number) ?? 0

      db.prepare('UPDATE face_clusters SET member_count = ? WHERE id = ?').run(originalMemberCount, sourceClusterId)
      db.prepare('UPDATE face_clusters SET member_count = ?, status = ? WHERE id = ?').run(
        Math.max(0, targetCount.count - originalMemberCount),
        targetCount.count - originalMemberCount > 0 ? 'unbound' : 'unbound',
        targetClusterId,
      )

      const sourceBinding = before.source_binding as { clusterId: string; roleName: string; keywords: string[] } | undefined
      if (sourceBinding) {
        db.prepare('INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)').run(
          sourceClusterId,
          before.session_id as string,
          sourceBinding.roleName,
          JSON.stringify(sourceBinding.keywords),
        )
        db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(sourceClusterId)
      }
    })

    restoreTransaction()
  },

  culling_batch: (_params, before) => {
    const decisions = before.decisions as Array<{ photo_id: string; session_id: string; decision: string }> | undefined
    if (!decisions || decisions.length === 0) return

    const db = getDatabase()
    const restoreTransaction = db.transaction(() => {
      for (const d of decisions) {
        db.prepare(
          'UPDATE culling_decisions SET decision = ? WHERE session_id = ? AND photo_id = ?',
        ).run(d.decision, d.session_id, d.photo_id)
      }
    })
    restoreTransaction()
  },

  dup_resolve: (_params, before) => {
    const members = before.members as Array<{ id: number; is_kept: number }> | undefined
    if (!members || members.length === 0) return

    const db = getDatabase()
    const groupId = before.group_id as number
    const restoreTransaction = db.transaction(() => {
      for (const m of members) {
        db.prepare('UPDATE duplicate_group_members SET is_kept = ? WHERE id = ?').run(m.is_kept, m.id)
      }
      if (groupId) {
        db.prepare('UPDATE duplicate_groups SET resolution = NULL WHERE id = ?').run(groupId)
      }
    })
    restoreTransaction()
  },

  template_apply: (_params, before) => {
    const sessionId = before.session_id as string
    const config = before.config as Record<string, unknown> | undefined
    if (!sessionId) return

    const db = getDatabase()

    if (config) {
      db.prepare('UPDATE sessions SET analysis_status = ? WHERE id = ?').run(
        (config.analysis_status as string) ?? 'idle',
        sessionId,
      )
    }
  },
}
