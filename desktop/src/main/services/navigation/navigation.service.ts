import crypto from 'node:crypto'
import path from 'node:path'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import type { NavigationGroup, NavigationGroupType } from '@gather/shared'

interface CaptureRow {
  id: string
  filepath: string
  filename: string
  capturedAt: string
  cameraModel: string
  hashHex: string
  rating: number
  qualityScore: number
  qualityWarnings: string[]
  hasQuality: boolean
}

export function validateNavigationParameters(
  burstGapSeconds: number,
  sceneGapSeconds: number,
): void {
  if (!Number.isFinite(burstGapSeconds) || burstGapSeconds < 0.1 || burstGapSeconds > 300) {
    throw new Error('连拍间隔必须在 0.1 到 300 秒之间')
  }
  if (!Number.isFinite(sceneGapSeconds) || sceneGapSeconds < burstGapSeconds || sceneGapSeconds > 86_400) {
    throw new Error('场景间隔必须不小于连拍间隔，且不超过 24 小时')
  }
}

function filenameSequence(filename: string): number | null {
  const match = path.basename(filename, path.extname(filename)).match(/(\d+)(?!.*\d)/)
  return match ? Number(match[1]) : null
}

function hammingDistance(left: string, right: string): number | null {
  if (!left || !right || left.length !== right.length) return null
  let distance = 0
  try {
    const a = BigInt(`0x${left}`)
    const b = BigInt(`0x${right}`)
    let value = a ^ b
    while (value) {
      distance++
      value &= value - 1n
    }
    return distance
  } catch {
    return null
  }
}

function safeQuality(value: string | null): {
  qualityScore: number
  warnings: string[]
  hasQuality: boolean
} {
  if (!value) return { qualityScore: 0, warnings: [], hasQuality: false }
  try {
    const parsed = JSON.parse(value) as {
      status?: unknown
      qualityScore?: unknown
      warnings?: unknown
    }
    return {
      qualityScore: typeof parsed.qualityScore === 'number' ? parsed.qualityScore : 0,
      warnings: Array.isArray(parsed.warnings)
        ? parsed.warnings.filter((warning): warning is string => typeof warning === 'string')
        : [],
      hasQuality: parsed.status !== 'failed' && typeof parsed.qualityScore === 'number',
    }
  } catch {
    return { qualityScore: 0, warnings: [], hasQuality: false }
  }
}

@injectable()
export class NavigationService {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  analyze(
    sessionId: string,
    burstGapSeconds = 2,
    sceneGapSeconds = 1_800,
    dryRun = false,
  ): NavigationGroup[] {
    validateNavigationParameters(burstGapSeconds, sceneGapSeconds)
    const rows = this.captureRows(sessionId)
    const fingerprint = crypto.createHash('sha256').update(JSON.stringify(
      [
        burstGapSeconds,
        sceneGapSeconds,
        // The lead ranking mixes quality score, rating and quality warnings,
        // so all three must be part of the fingerprint — otherwise a rating
        // change (or a re-run of quality analysis) would leave the cached
        // groups and their stale lead recommendations in place. Warnings are
        // sorted so a non-deterministic storage order cannot spuriously
        // invalidate (and rebuild with new ids) every automatic group.
        rows.map(row => [
          row.id,
          row.capturedAt,
          row.hashHex,
          row.rating,
          row.qualityScore,
          [...row.qualityWarnings].sort(),
        ]),
      ],
    )).digest('hex')
    if (!dryRun) {
      const cached = this.list(sessionId)
      const cachedFingerprint = this.db.prepare(`
        SELECT input_fingerprint FROM navigation_groups
        WHERE session_id = ? AND source = 'automatic' LIMIT 1
      `).get(sessionId) as { input_fingerprint: string } | undefined
      if (cached.length > 0 && cachedFingerprint?.input_fingerprint === fingerprint) return cached
    }

    // Build the photo lookup once: withLead previously rebuilt the full
    // rows-by-id map for every group (O(groups × rows) on large sessions).
    const byId = new Map(rows.map(row => [row.id, row]))
    const groups = [
      ...this.group(rows, 'burst', burstGapSeconds),
      ...this.group(rows, 'scene', sceneGapSeconds),
    ].map(group => this.withLead(group, byId))
    if (!dryRun) {
      this.persistAutomatic(sessionId, groups, fingerprint)
      return this.list(sessionId)
    }
    return groups
  }

  list(sessionId: string): NavigationGroup[] {
    const rows = this.db.prepare(`
      SELECT id, group_type, photo_ids_json, lead_photo_id, explanation, source
      FROM navigation_groups WHERE session_id = ?
      ORDER BY group_type, created_at, id
    `).all(sessionId) as Array<{
      id: string
      group_type: NavigationGroupType
      photo_ids_json: string
      lead_photo_id: string | null
      explanation: string
      source: 'automatic' | 'manual'
    }>
    const capturedAt = new Map(this.captureRows(sessionId).map(row => [row.id, row.capturedAt]))
    return rows.flatMap(row => {
      try {
        const photoIds = JSON.parse(row.photo_ids_json) as string[]
        if (!Array.isArray(photoIds) || photoIds.length < 2) return []
        return [{
          id: row.id,
          type: row.group_type,
          photoIds,
          startAt: capturedAt.get(photoIds[0]) ?? '',
          endAt: capturedAt.get(photoIds[photoIds.length - 1]) ?? '',
          leadPhotoId: row.lead_photo_id ?? undefined,
          explanation: row.explanation,
          source: row.source,
        }]
      } catch {
        return []
      }
    })
  }

  split(sessionId: string, groupId: string, beforePhotoId: string): NavigationGroup[] {
    const group = this.list(sessionId).find(candidate => candidate.id === groupId)
    if (!group) throw new Error('Navigation group not found')
    const splitIndex = group.photoIds.indexOf(beforePhotoId)
    if (splitIndex <= 0 || splitIndex >= group.photoIds.length) {
      throw new Error('Split point must be inside the group')
    }
    const rows = this.captureRows(sessionId)
    const byId = new Map(rows.map(row => [row.id, row]))
    const replacements = [
      { ...group, id: crypto.randomUUID(), photoIds: group.photoIds.slice(0, splitIndex), source: 'manual' as const },
      { ...group, id: crypto.randomUUID(), photoIds: group.photoIds.slice(splitIndex), source: 'manual' as const },
    ].map(candidate => this.withLead(candidate, byId))
    this.db.transaction(() => {
      this.db.prepare('DELETE FROM navigation_groups WHERE id = ? AND session_id = ?')
        .run(groupId, sessionId)
      replacements.forEach(candidate => this.insertGroup(sessionId, candidate, 'manual', ''))
    })()
    return this.list(sessionId)
  }

  merge(sessionId: string, groupIds: string[]): NavigationGroup[] {
    const uniqueIds = [...new Set(groupIds)]
    if (uniqueIds.length < 2) throw new Error('At least two groups are required')
    const selected = this.list(sessionId).filter(group => uniqueIds.includes(group.id))
    if (selected.length !== uniqueIds.length) throw new Error('Navigation group not found')
    if (new Set(selected.map(group => group.type)).size !== 1) {
      throw new Error('Only groups of the same type can be merged')
    }
    // captureRows is a heavy query (correlated quality sub-select per photo);
    // fetch it once and derive both the merge order and the lead rankings.
    const rows = this.captureRows(sessionId)
    const byId = new Map(rows.map(row => [row.id, row]))
    const order = new Map(rows.map((row, index) => [row.id, index]))
    const photoIds = [...new Set(selected.flatMap(group => group.photoIds))]
      .sort((left, right) => (order.get(left) ?? 0) - (order.get(right) ?? 0))
    const merged = this.withLead({
      id: crypto.randomUUID(),
      type: selected[0].type,
      photoIds,
      startAt: '',
      endAt: '',
      explanation: '',
      source: 'manual',
    }, byId)
    this.db.transaction(() => {
      const placeholders = uniqueIds.map(() => '?').join(', ')
      this.db.prepare(`
        DELETE FROM navigation_groups
        WHERE session_id = ? AND id IN (${placeholders})
      `).run(sessionId, ...uniqueIds)
      this.insertGroup(sessionId, merged, 'manual', '')
    })()
    return this.list(sessionId)
  }

  private captureRows(sessionId: string): CaptureRow[] {
    const rows = this.db.prepare(`
      SELECT p.id, p.filepath, p.filename,
        COALESCE(NULLIF(pmc.date_taken, ''), p.created_at) AS captured_at,
        COALESCE(pmc.camera_model, '') AS camera_model,
        COALESCE(sh.hash_hex, '') AS hash_hex,
        COALESCE(pmc.rating, 0) AS rating,
        (
          SELECT aa.result_json FROM asset_analysis aa
          WHERE aa.asset_file_id = p.asset_file_id AND aa.analysis_type = 'technical_quality'
          ORDER BY aa.updated_at DESC LIMIT 1
        ) AS quality_json
      FROM photos p
      LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
      LEFT JOIN similarity_hashes sh ON sh.photo_id = p.id AND sh.session_id = p.session_id
      WHERE p.session_id = ? AND p.status != 'missing'
      ORDER BY captured_at, p.rowid
    `).all(sessionId) as Array<{
      id: string
      filepath: string
      filename: string
      captured_at: string
      camera_model: string
      hash_hex: string
      rating: number
      quality_json: string | null
    }>
    return rows.map(row => {
      const quality = safeQuality(row.quality_json)
      return {
        id: row.id,
        filepath: row.filepath,
        filename: row.filename,
        capturedAt: row.captured_at,
        cameraModel: row.camera_model,
        hashHex: row.hash_hex,
        rating: row.rating,
        qualityScore: quality.qualityScore,
        qualityWarnings: quality.warnings,
        hasQuality: quality.hasQuality,
      }
    })
  }

  private group(rows: CaptureRow[], type: NavigationGroupType, gapSeconds: number): NavigationGroup[] {
    const groups: NavigationGroup[] = []
    let current: CaptureRow[] = []
    const flush = () => {
      if (current.length >= 2) {
        groups.push({
          id: crypto.randomUUID(),
          type,
          photoIds: current.map(row => row.id),
          startAt: current[0].capturedAt,
          endAt: current[current.length - 1].capturedAt,
          explanation: '',
          source: 'automatic',
        })
      }
      current = []
    }
    for (const row of rows) {
      const previous = current[current.length - 1]
      const gap = previous ? (Date.parse(row.capturedAt) - Date.parse(previous.capturedAt)) / 1000 : 0
      const directoryChanged = Boolean(
        previous && path.dirname(previous.filepath) !== path.dirname(row.filepath),
      )
      const sameCamera = !previous || !previous.cameraModel || !row.cameraModel ||
        previous.cameraModel === row.cameraModel
      const previousSequence = previous ? filenameSequence(previous.filename) : null
      const currentSequence = filenameSequence(row.filename)
      const sequential = previousSequence === null || currentSequence === null ||
        (currentSequence > previousSequence && currentSequence - previousSequence <= 3)
      const visualDistance = previous ? hammingDistance(previous.hashHex, row.hashHex) : null
      const visuallyRelated = visualDistance === null || visualDistance <= (type === 'burst' ? 14 : 24)
      const boundary = previous && (
        !Number.isFinite(gap) ||
        gap < 0 ||
        gap > gapSeconds ||
        !sameCamera ||
        (type === 'burst' && (!sequential || !visuallyRelated)) ||
        (type === 'scene' && (directoryChanged || !visuallyRelated))
      )
      if (boundary) flush()
      current.push(row)
    }
    flush()
    return groups
  }

  private withLead(group: NavigationGroup, byId: Map<string, CaptureRow>): NavigationGroup {
    const hasAnyQuality = group.photoIds.some(photoId => byId.get(photoId)?.hasQuality)
    const ranked = group.photoIds
      .flatMap(photoId => byId.get(photoId) ?? [])
      .sort((left, right) => {
        if (!hasAnyQuality) return right.rating - left.rating
        const hasClosedEyeRisk = (warnings: string[]) =>
          warnings.includes('closed_eye_risk_heuristic') ||
          warnings.includes('closed_eye_risk')
        const leftPenalty = hasClosedEyeRisk(left.qualityWarnings) ? 0.25 : 0
        const rightPenalty = hasClosedEyeRisk(right.qualityWarnings) ? 0.25 : 0
        return (right.qualityScore + right.rating * 0.08 - rightPenalty) -
          (left.qualityScore + left.rating * 0.08 - leftPenalty)
      })
    const lead = ranked[0]
    return {
      ...group,
      startAt: byId.get(group.photoIds[0])?.capturedAt ?? group.startAt,
      endAt: byId.get(group.photoIds[group.photoIds.length - 1])?.capturedAt ?? group.endAt,
      leadPhotoId: lead?.id,
      explanation: lead && hasAnyQuality
        ? `推荐 ${lead.filename}：质量 ${Math.round(lead.qualityScore * 100)}，星级 ${lead.rating}`
        : lead?.rating
          ? `尚无可用质量评分；按人工星级选择 ${lead.filename}`
          : '尚无可用质量评分或人工星级，按拍摄顺序选择首张',
    }
  }

  private persistAutomatic(
    sessionId: string,
    groups: NavigationGroup[],
    fingerprint: string,
  ): void {
    const manualRows = this.db.prepare(`
      SELECT group_type, photo_ids_json FROM navigation_groups
      WHERE session_id = ? AND source = 'manual'
    `).all(sessionId) as Array<{
      group_type: NavigationGroupType
      photo_ids_json: string
    }>
    const manuallyGrouped = new Map<NavigationGroupType, Set<string>>([
      ['burst', new Set()],
      ['scene', new Set()],
    ])
    for (const row of manualRows) {
      try {
        const ids = JSON.parse(row.photo_ids_json) as unknown
        if (Array.isArray(ids)) {
          ids.forEach(id => {
            if (typeof id === 'string') manuallyGrouped.get(row.group_type)?.add(id)
          })
        }
      } catch { /* ignore invalid historical row */ }
    }
    const automaticGroups = groups.flatMap(group => {
      const photoIds = group.photoIds.filter(
        photoId => !manuallyGrouped.get(group.type)?.has(photoId),
      )
      return photoIds.length >= 2
        ? [{ ...group, id: crypto.randomUUID(), photoIds }]
        : []
    })
    this.db.transaction(() => {
      this.db.prepare(
        "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
      ).run(sessionId)
      automaticGroups.forEach(group => this.insertGroup(sessionId, group, 'automatic', fingerprint))
    })()
  }

  private insertGroup(
    sessionId: string,
    group: NavigationGroup,
    source: 'automatic' | 'manual',
    fingerprint: string,
  ): void {
    const now = new Date().toISOString()
    this.db.prepare(`
      INSERT INTO navigation_groups (
        id, session_id, group_type, photo_ids_json, lead_photo_id,
        explanation, input_fingerprint, source, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      group.id,
      sessionId,
      group.type,
      JSON.stringify(group.photoIds),
      group.leadPhotoId ?? null,
      group.explanation,
      fingerprint,
      source,
      now,
      now,
    )
  }
}
