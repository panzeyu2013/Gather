import { getDatabase } from '../../db/database'
import type {
  DuplicateScanResult,
  DuplicateGroup,
} from '@gather/shared'

function hammingDistance(a: string, b: string): number {
  let dist = 0
  for (let i = 0; i < a.length; i++) {
    const xor = parseInt(a[i], 16) ^ parseInt(b[i], 16)
    dist += [0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4][xor]
  }
  return dist
}

function unionFind(ids: string[], edges: [string, string][]): string[][] {
  const parent = new Map<string, string>()
  const rank = new Map<string, number>()

  for (const id of ids) {
    parent.set(id, id)
    rank.set(id, 0)
  }

  function find(x: string): string {
    const p = parent.get(x)
    if (p !== x) {
      parent.set(x, find(p!))
    }
    return parent.get(x)!
  }

  function union(x: string, y: string): void {
    const rx = find(x)
    const ry = find(y)
    if (rx === ry) return
    const rankX = rank.get(rx) ?? 0
    const rankY = rank.get(ry) ?? 0
    if (rankX < rankY) {
      parent.set(rx, ry)
    } else if (rankX > rankY) {
      parent.set(ry, rx)
    } else {
      parent.set(ry, rx)
      rank.set(rx, rankX + 1)
    }
  }

  for (const [a, b] of edges) {
    union(a, b)
  }

  const groups = new Map<string, string[]>()
  for (const id of ids) {
    const root = find(id)
    const list = groups.get(root) ?? []
    list.push(id)
    groups.set(root, list)
  }

  return Array.from(groups.values()).filter((g) => g.length >= 2)
}

export class DuplicateService {
  scanDuplicates(
    sessionId: string,
    sessionIds?: string[],
    visualThreshold?: number,
  ): DuplicateScanResult {
    const db = getDatabase()
    const threshold = visualThreshold ?? 4
    const ids = sessionIds && sessionIds.length > 0 ? sessionIds : [sessionId]
    const placeholders = ids.map(() => '?').join(',')
    const now = new Date().toISOString()

    const exactGroupIds: number[] = []
    const visualGroupIds: number[] = []

    const scanTransaction = db.transaction(() => {
      db.prepare('DELETE FROM duplicate_group_members WHERE session_id IN (' + placeholders + ')').run(...ids)
      db.prepare('DELETE FROM duplicate_groups WHERE session_id IN (' + placeholders + ')').run(...ids)

      db.pragma('group_concat_limit = 0')

      const exactRows = db
        .prepare(
          `SELECT checksum, COUNT(*) as cnt, GROUP_CONCAT(id) as photo_ids
           FROM photos
           WHERE session_id IN (${placeholders}) AND checksum != ''
           GROUP BY checksum
           HAVING COUNT(*) > 1`,
        )
        .all(...ids) as { checksum: string; cnt: number; photo_ids: string }[]

      const insertGroup = db.prepare(
        'INSERT INTO duplicate_groups (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at) VALUES (?, ?, ?, ?, ?, NULL, ?)',
      )
      const insertMember = db.prepare(
        'INSERT INTO duplicate_group_members (group_id, photo_id, session_id, is_kept, file_size, file_mtime) VALUES (?, ?, ?, 1, NULL, NULL)',
      )

      for (const row of exactRows) {
        const photoIds = row.photo_ids.split(',')
        const result = insertGroup.run(sessionId, 'exact', row.checksum, null, photoIds.length, now)
        const groupId = result.lastInsertRowid as number
        exactGroupIds.push(groupId)
        for (const photoId of photoIds) {
          insertMember.run(groupId, photoId, sessionId)
        }
      }

      const hashRows = db
        .prepare(
          `SELECT sh.photo_id, sh.hash_hex
           FROM similarity_hashes sh
           JOIN photos p ON p.id = sh.photo_id
           WHERE p.session_id IN (${placeholders})
           ORDER BY sh.photo_id`,
        )
        .all(...ids) as { photo_id: string; hash_hex: string }[]

      if (hashRows.length >= 2) {
        const edges: [string, string][] = []
        for (let i = 0; i < hashRows.length; i++) {
          for (let j = i + 1; j < hashRows.length; j++) {
            if (hammingDistance(hashRows[i].hash_hex, hashRows[j].hash_hex) <= threshold) {
              edges.push([hashRows[i].photo_id, hashRows[j].photo_id])
            }
          }
        }

        const components = unionFind(
          hashRows.map((r) => r.photo_id),
          edges,
        )

        for (const memberIds of components) {
          const firstHash = hashRows.find((r) => r.photo_id === memberIds[0])!.hash_hex
          const result = insertGroup.run(sessionId, 'visual', null, firstHash, memberIds.length, now)
          const groupId = result.lastInsertRowid as number
          visualGroupIds.push(groupId)
          for (const photoId of memberIds) {
            insertMember.run(groupId, photoId, sessionId)
          }
        }
      }
    })

    scanTransaction()

    return this.buildResult(exactGroupIds, visualGroupIds)
  }

  getGroups(sessionId: string): DuplicateGroup[] {
    const db = getDatabase()

    const groupRows = db
      .prepare(
        `SELECT * FROM duplicate_groups
         WHERE session_id = ?
         ORDER BY group_type, id`,
      )
      .all(sessionId) as {
      id: number
      session_id: string
      group_type: string
      checksum: string | null
      hash_hex: string | null
      member_count: number
      resolution: string | null
      created_at: string
    }[]

    if (groupRows.length === 0) return []

    const groupIds = groupRows.map((g) => g.id)
    const placeholders = groupIds.map(() => '?').join(',')

    const memberRows = db
      .prepare(
        `SELECT dgm.*, p.filepath, p.filename
         FROM duplicate_group_members dgm
         JOIN photos p ON p.id = dgm.photo_id
         WHERE dgm.group_id IN (${placeholders})
         ORDER BY dgm.id`,
      )
      .all(...groupIds) as {
      id: number
      group_id: number
      photo_id: string
      session_id: string
      is_kept: number
      file_size: number | null
      file_mtime: string | null
      resolution: string | null
      filepath: string
      filename: string
    }[]

    const memberMap = new Map<number, typeof memberRows>()
    for (const m of memberRows) {
      const list = memberMap.get(m.group_id) ?? []
      list.push(m)
      memberMap.set(m.group_id, list)
    }

    return groupRows.map((g) => ({
      id: g.id,
      groupType: g.group_type as 'exact' | 'visual',
      checksum: g.checksum ?? undefined,
      hashHex: g.hash_hex ?? undefined,
      memberCount: g.member_count,
      resolution: g.resolution,
      createdAt: g.created_at,
      members: (memberMap.get(g.id) ?? []).map((m) => ({
        id: m.id,
        photoId: m.photo_id,
        isKept: m.is_kept === 1,
        fileSize: m.file_size,
        fileMtime: m.file_mtime,
        resolution: m.resolution,
        filepath: m.filepath,
        filename: m.filename,
      })),
    }))
  }

  resolveGroup(
    groupId: number,
    resolution: 'keep_one' | 'keep_all',
  ): void {
    const db = getDatabase()

    const resolveTransaction = db.transaction(() => {
      db.prepare('UPDATE duplicate_groups SET resolution = ? WHERE id = ?').run(
        resolution,
        groupId,
      )

      const members = db
        .prepare('SELECT * FROM duplicate_group_members WHERE group_id = ?')
        .all(groupId) as {
        id: number
        photo_id: string
        file_size: number | null
        file_mtime: string | null
      }[]

      if (resolution === 'keep_all') {
        for (const m of members) {
          db.prepare(
            'UPDATE duplicate_group_members SET is_kept = 1, resolution = ? WHERE id = ?',
          ).run(resolution, m.id)
        }
      } else {
        let bestId = members[0].id
        let bestScore = -1

        for (const m of members) {
          const score = (m.file_size ?? 0) * 1000 + new Date(m.file_mtime || 0).getTime()
          if (score > bestScore) {
            bestScore = score
            bestId = m.id
          }
        }

        for (const m of members) {
          db.prepare(
            'UPDATE duplicate_group_members SET is_kept = ?, resolution = ? WHERE id = ?',
          ).run(m.id === bestId ? 1 : 0, resolution, m.id)
        }
      }
    })

    resolveTransaction()
  }

  resolveMember(memberId: number, isKept: boolean): void {
    const db = getDatabase()
    db.prepare(
      'UPDATE duplicate_group_members SET is_kept = ?, resolution = COALESCE(resolution, ?) WHERE id = ?',
    ).run(isKept ? 1 : 0, isKept ? 'keep_all' : 'keep_one', memberId)
  }

  private buildResult(
    exactGroupIds: number[],
    visualGroupIds: number[],
  ): DuplicateScanResult {
    const db = getDatabase()
    const exactGroups: DuplicateGroup[] = []
    const visualGroups: DuplicateGroup[] = []

    for (const ids of [exactGroupIds, visualGroupIds]) {
      if (ids.length === 0) continue
      const placeholders = ids.map(() => '?').join(',')

      const groups = db
        .prepare(
          `SELECT * FROM duplicate_groups WHERE id IN (${placeholders}) ORDER BY id`,
        )
        .all(...ids) as {
        id: number
        session_id: string
        group_type: string
        checksum: string | null
        hash_hex: string | null
        member_count: number
        resolution: string | null
        created_at: string
      }[]

      const memberRows = db
        .prepare(
          `SELECT dgm.*, p.filepath, p.filename
           FROM duplicate_group_members dgm
           JOIN photos p ON p.id = dgm.photo_id
           WHERE dgm.group_id IN (${placeholders})
           ORDER BY dgm.id`,
        )
        .all(...ids) as {
        id: number
        group_id: number
        photo_id: string
        is_kept: number
        file_size: number | null
        file_mtime: string | null
        resolution: string | null
        filepath: string
        filename: string
      }[]

      const memberMap = new Map<number, typeof memberRows>()
      for (const m of memberRows) {
        const list = memberMap.get(m.group_id) ?? []
        list.push(m)
        memberMap.set(m.group_id, list)
      }

      for (const g of groups) {
        const group: DuplicateGroup = {
          id: g.id,
          groupType: g.group_type as 'exact' | 'visual',
          checksum: g.checksum ?? undefined,
          hashHex: g.hash_hex ?? undefined,
          memberCount: g.member_count,
          resolution: g.resolution,
          createdAt: g.created_at,
          members: (memberMap.get(g.id) ?? []).map((m) => ({
            id: m.id,
            photoId: m.photo_id,
            isKept: m.is_kept === 1,
            fileSize: m.file_size,
            fileMtime: m.file_mtime,
            resolution: m.resolution,
            filepath: m.filepath,
            filename: m.filename,
          })),
        }

        if (g.group_type === 'exact') {
          exactGroups.push(group)
        } else {
          visualGroups.push(group)
        }
      }
    }

    const totalDuplicates = exactGroups.reduce((sum, g) => sum + g.memberCount, 0) +
      visualGroups.reduce((sum, g) => sum + g.memberCount, 0)

    return { exactGroups, visualGroups, totalDuplicates }
  }
}
