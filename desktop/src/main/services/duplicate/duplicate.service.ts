import { Database } from '../../db/database'
import type {
  DuplicateScanResult,
  DuplicateGroup,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { createReadStream } from 'fs'
import { stat } from 'fs/promises'
import { createHash } from 'crypto'
import { batchAsync } from '../../utils/async'
import { computeDHash } from '../similarity/hash-computer'
import type { ImageService } from '../image'
import { clusterByHash } from '../similarity/cluster-engine'

export function excludeExactDuplicateHashes<T extends { photo_id: string }>(
  rows: T[],
  exactPhotoIds: ReadonlySet<string>,
): T[] {
  return rows.filter((row) => !exactPhotoIds.has(row.photo_id))
}

async function sha256File(filePath: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk as Buffer)
  }
  return hash.digest('hex')
}

export async function computeVisualHashes(
  photos: Array<{ id: string; filepath: string }>,
  imageService: Pick<ImageService, 'getThumbnail'>,
): Promise<Map<string, string>> {
  const hashes = new Map<string, string>()
  await batchAsync(photos, async (photo) => {
    try {
      const preview = await imageService.getThumbnail(photo.filepath, 256)
      hashes.set(photo.id, await computeDHash(preview.buffer))
    } catch {
      // A corrupt image should not prevent exact duplicate detection.
    }
  }, 2)
  return hashes
}

@injectable()
export class DuplicateService {
  private scanPromise: Promise<DuplicateScanResult> | null = null
  private scanSessionId: string | null = null
  private scanThreshold: number | undefined = undefined

  constructor(
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.IMAGE_SERVICE) private imageService: ImageService,
  ) {}

  async scanDuplicates(
    sessionId: string,
    visualThreshold?: number,
    signal?: AbortSignal,
    onProgress?: (current: number, total: number, message: string) => void,
  ): Promise<DuplicateScanResult> {
    if (this.scanPromise) {
      if (this.scanSessionId === sessionId && this.scanThreshold === visualThreshold) return this.scanPromise
      throw new Error('A scan is already in progress with different parameters')
    }

    this.scanSessionId = sessionId
    this.scanThreshold = visualThreshold
    this.scanPromise = this._scanDuplicates(sessionId, visualThreshold, signal, onProgress)
    try {
      return await this.scanPromise
    } finally {
      this.scanPromise = null
      this.scanSessionId = null
      this.scanThreshold = undefined
    }
  }

  private async _scanDuplicates(
    sessionId: string,
    visualThreshold: number | undefined,
    signal?: AbortSignal,
    onProgress?: (current: number, total: number, message: string) => void,
  ): Promise<DuplicateScanResult> {
    if (signal?.aborted) throw new Error('Duplicate scan cancelled')
    const db = this.db
    const threshold = visualThreshold ?? 4
    const ids = [sessionId]
    const placeholders = ids.map(() => '?').join(',')
    const now = new Date().toISOString()

    const exactGroupIds: number[] = []
    const visualGroupIds: number[] = []

    const allPhotos = db
      .prepare(
        `SELECT id, filepath, checksum, checksum_file_size, checksum_file_mtime_ms
         FROM photos WHERE session_id IN (${placeholders})`,
      )
      .all(...ids) as Array<{
        id: string
        filepath: string
        checksum: string
        checksum_file_size: number
        checksum_file_mtime_ms: number
      }>

    const photoById = new Map(allPhotos.map((p) => [p.id, p]))
    const photoMeta = new Map<string, { size: number; mtime: string; mtimeMs: number }>()
    const sizeGroups = new Map<number, string[]>()

    await batchAsync(allPhotos, async (p) => {
      if (signal?.aborted) throw new Error('Duplicate scan cancelled')
      try {
        const sourceStat = await stat(p.filepath)
        photoMeta.set(p.id, {
          size: sourceStat.size,
          mtime: sourceStat.mtime.toISOString(),
          mtimeMs: sourceStat.mtimeMs,
        })
        const group = sizeGroups.get(sourceStat.size) ?? []
        group.push(p.id)
        sizeGroups.set(sourceStat.size, group)
      } catch {
        // skip unreadable files
      }
    }, 32)
    onProgress?.(allPhotos.length, allPhotos.length * 3, '正在读取文件信息')

    const resolvedChecksums = new Map<string, string>()
    for (const photo of allPhotos) {
      const meta = photoMeta.get(photo.id)
      if (
        meta &&
        photo.checksum &&
        photo.checksum_file_size === meta.size &&
        Math.abs(photo.checksum_file_mtime_ms - meta.mtimeMs) < 1
      ) {
        resolvedChecksums.set(photo.id, photo.checksum)
      }
    }
    const candidatePhotos: { id: string; filepath: string }[] = []
    for (const [, photoIds] of sizeGroups) {
      if (photoIds.length < 2) continue
      for (const photoId of photoIds) {
        const p = photoById.get(photoId)!
        if (!resolvedChecksums.has(photoId)) {
          candidatePhotos.push(p)
        }
      }
    }

    await batchAsync(candidatePhotos, async (photo) => {
      if (signal?.aborted) throw new Error('Duplicate scan cancelled')
      try {
        const checksum = await sha256File(photo.filepath)
        resolvedChecksums.set(photo.id, checksum)
      } catch {
        // skip unreadable files
      }
    }, 2)
    onProgress?.(
      allPhotos.length + candidatePhotos.length,
      allPhotos.length * 3,
      '正在计算内容校验和',
    )

    const existingVisualRows = db.prepare(
      `SELECT photo_id, hash_hex, file_size, file_mtime_ms
       FROM similarity_hashes WHERE session_id IN (${placeholders})`,
    ).all(...ids) as Array<{
      photo_id: string
      hash_hex: string
      file_size: number
      file_mtime_ms: number
    }>
    const resolvedVisualHashes = new Map<string, string>()
    for (const row of existingVisualRows) {
      const meta = photoMeta.get(row.photo_id)
      if (
        meta &&
        meta.size === row.file_size &&
        Math.abs(meta.mtimeMs - row.file_mtime_ms) < 1
      ) {
        resolvedVisualHashes.set(row.photo_id, row.hash_hex)
      }
    }
    const visualMisses = allPhotos.filter(photo => !resolvedVisualHashes.has(photo.id))
    if (signal?.aborted) throw new Error('Duplicate scan cancelled')
    const computedVisualHashes = await computeVisualHashes(visualMisses, this.imageService)
    // computeVisualHashes does not observe the abort signal, so re-check before
    // persisting: a cancellation that arrived mid-computation must not still
    // write hashes and rebuild duplicate groups into the database.
    if (signal?.aborted) throw new Error('Duplicate scan cancelled')
    for (const [photoId, hash] of computedVisualHashes) {
      resolvedVisualHashes.set(photoId, hash)
    }
    onProgress?.(allPhotos.length * 3, allPhotos.length * 3, '重复扫描完成')

    const persistAnalysisData = db.transaction(() => {
      const update = db.prepare(
        `UPDATE photos
         SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
         WHERE id = ?`,
      )
      for (const photo of allPhotos) {
        const meta = photoMeta.get(photo.id)
        update.run(
          resolvedChecksums.get(photo.id) ?? '',
          meta?.size ?? 0,
          meta?.mtimeMs ?? 0,
          photo.id,
        )
      }
      const insertHash = db.prepare(
        `INSERT INTO similarity_hashes
           (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(session_id, photo_id) DO UPDATE SET
           hash_hex = excluded.hash_hex,
           file_size = excluded.file_size,
           file_mtime_ms = excluded.file_mtime_ms`,
      )
      for (const [photoId, hash] of resolvedVisualHashes) {
        const meta = photoMeta.get(photoId)
        insertHash.run(sessionId, photoId, hash, meta?.size ?? 0, meta?.mtimeMs ?? 0)
      }
    })
    persistAnalysisData()

    const scanTransaction = db.transaction(() => {
      db.prepare(`
        UPDATE photos
        SET status = 'ready'
        WHERE id IN (
          SELECT photo_id
          FROM duplicate_group_members
          WHERE session_id IN (${placeholders})
        )
        AND status = 'removed'
      `).run(...ids)
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
        'INSERT INTO duplicate_group_members (group_id, photo_id, session_id, is_kept, file_size, file_mtime) VALUES (?, ?, ?, 1, ?, ?)',
      )

      const exactPhotoIds = new Set<string>()
      for (const row of exactRows) {
        const photoIds = row.photo_ids.split(',')
        const result = insertGroup.run(sessionId, 'exact', row.checksum, null, photoIds.length, now)
        const groupId = result.lastInsertRowid as number
        exactGroupIds.push(groupId)
        for (const photoId of photoIds) {
          exactPhotoIds.add(photoId)
          const meta = photoMeta.get(photoId)
          insertMember.run(groupId, photoId, sessionId, meta?.size ?? null, meta?.mtime ?? null)
        }
      }

      const hashRows = excludeExactDuplicateHashes(
        db
        .prepare(
          `SELECT sh.photo_id, sh.hash_hex
           FROM similarity_hashes sh
           JOIN photos p ON p.id = sh.photo_id
           WHERE p.session_id IN (${placeholders})
           ORDER BY sh.photo_id`,
        )
        .all(...ids) as { photo_id: string; hash_hex: string }[],
        exactPhotoIds,
      )

      if (hashRows.length >= 2) {
        const hashByPhotoId = new Map(
          hashRows.map(row => [row.photo_id, row.hash_hex]),
        )
        const components = clusterByHash(
          hashRows.map(row => ({ photoId: row.photo_id, hash: row.hash_hex })),
          threshold,
          2,
        ).groups

        for (const memberIds of components) {
          const firstHash = hashByPhotoId.get(memberIds[0])!
          const result = insertGroup.run(sessionId, 'visual', null, firstHash, memberIds.length, now)
          const groupId = result.lastInsertRowid as number
          visualGroupIds.push(groupId)
          for (const photoId of memberIds) {
            const meta = photoMeta.get(photoId)
            insertMember.run(groupId, photoId, sessionId, meta?.size ?? null, meta?.mtime ?? null)
          }
        }
      }
    })

    scanTransaction()

    return this.buildResult(exactGroupIds, visualGroupIds)
  }

  getGroups(sessionId: string): DuplicateGroup[] {
    const db = this.db

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
    const db = this.db

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
      if (members.length === 0) {
        throw new Error(`Duplicate group ${groupId} was not found or has no members`)
      }

      if (resolution === 'keep_all') {
        const updateMember = db.prepare(
          'UPDATE duplicate_group_members SET is_kept = 1, resolution = ? WHERE id = ?',
        )
        for (const m of members) {
          updateMember.run(resolution, m.id)
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

        const updateMember = db.prepare(
          'UPDATE duplicate_group_members SET is_kept = ?, resolution = ? WHERE id = ?',
        )
        for (const m of members) {
          const isKept = m.id === bestId ? 1 : 0
          updateMember.run(isKept, resolution, m.id)
        }
      }
      this.recomputePhotoStatuses(members.map((member) => member.photo_id))
    })

    resolveTransaction()
  }

  resolveMember(memberId: number, isKept: boolean): void {
    const db = this.db
    const resolveTransaction = db.transaction(() => {
      db.prepare(
        'UPDATE duplicate_group_members SET is_kept = ?, resolution = COALESCE(resolution, ?) WHERE id = ?',
      ).run(isKept ? 1 : 0, isKept ? 'keep_all' : 'keep_one', memberId)

      const member = db.prepare('SELECT photo_id FROM duplicate_group_members WHERE id = ?').get(memberId) as { photo_id: string } | undefined
      if (!member) {
        throw new Error(`Duplicate member ${memberId} was not found`)
      }
      this.recomputePhotoStatuses([member.photo_id])
    })
    resolveTransaction()
  }

  private recomputePhotoStatuses(photoIds: string[]): void {
    if (photoIds.length === 0) return
    const uniqueIds = [...new Set(photoIds)]
    const placeholders = uniqueIds.map(() => '?').join(',')
    this.db.prepare(`
      UPDATE photos
      SET status = CASE
        WHEN EXISTS (
          SELECT 1
          FROM duplicate_group_members dgm
          WHERE dgm.photo_id = photos.id
            AND dgm.is_kept = 0
        ) THEN 'removed'
        ELSE 'ready'
      END
      WHERE id IN (${placeholders})
    `).run(...uniqueIds)
  }

  private buildResult(
    exactGroupIds: number[],
    visualGroupIds: number[],
  ): DuplicateScanResult {
    const db = this.db
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
