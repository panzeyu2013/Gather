import {
  PHOTO_PAGE_COLUMNS,
  PhotoRepository,
  RAW_EXTENSIONS,
  RAW_EXTENSION_LIKE_SQL,
  type PhotoPageRow,
  type PhotoProjectionRow,
  type PhotoRow,
} from '../../db/repositories/photo.repo'
import {
  CullingDecisionRepository,
  type CullingDecisionRow,
} from '../../db/repositories/culling-decision.repo'
import {
  SimilarityResultRepository,
  type SimilarityResultRow,
} from '../../db/repositories/similarity-result.repo'
import {
  MetadataCacheRepository,
  type MetadataCacheRow,
} from '../../db/repositories/metadata-cache.repo'
import {
  MetadataOutboxRepository,
  type MetadataOutboxRow,
} from '../../db/repositories/metadata-outbox.repo'
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
  CullingPage,
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

/** Precompiled lowercase RAW extension set: the preferred-variant check
 * becomes an O(1) extension probe instead of a per-candidate
 * `some(...endsWith)` scan. */
const PREFERRED_RAW_EXTENSIONS = new Set<string>(RAW_EXTENSIONS)

function isPreferredRawVariant(filename: string): boolean {
  const lower = filename.toLowerCase()
  const dot = lower.lastIndexOf('.')
  return dot >= 0 && PREFERRED_RAW_EXTENSIONS.has(lower.slice(dot))
}

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

/** Throw a GatherErrorCode with optional renderer interpolation params. */
function codedError(code: string, params?: Record<string, unknown>): Error {
  const error = new Error(code)
  if (params) {
    ;(error as Error & { params?: Record<string, unknown> }).params = params
  }
  return error
}

function photoRowToData(row: CullingPhotoRow, faceCount: number): PhotoData {
  return {
    id: row.id,
    sessionId: row.session_id,
    filepath: row.filepath,
    filename: row.filename,
    checksum: row.checksum ?? '',
    hasExistingXmp: false,
    faceCount,
    width: row.width ?? 0,
    height: row.height ?? 0,
    metadata: parseJsonRecord((row as PhotoPageRow).metadata ?? '{}'),
    result: parseJsonRecord((row as PhotoPageRow).result ?? '{}'),
    status: row.status,
    assetId: row.asset_id ?? undefined,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

/** asset_id → photos index of a photo set, built once per cached update
 * context so the per-asset variant sweep in `updateState` (pick-state
 * patches) is a map lookup instead of an O(n) scan of the session per
 * update. Photos without an asset id are skipped: the sweep only matches
 * photos sharing a real asset id (`photo.asset_id === target.asset_id` with
 * a truthy `target.asset_id`). */
function buildPhotosByAssetIndex(
  photos: CullingPhotoRow[],
): Map<string, CullingPhotoRow[]> {
  const photosByAssetId = new Map<string, CullingPhotoRow[]>()
  for (const photo of photos) {
    if (!photo.asset_id) continue
    const variants = photosByAssetId.get(photo.asset_id)
    if (variants) variants.push(photo)
    else photosByAssetId.set(photo.asset_id, [photo])
  }
  return photosByAssetId
}

/** Groups count of a similarity result row. The current pipeline writes
 * `totalGroups` into the small stats_json object (see similarity.service),
 * so the multi-MB groups_json is only parsed for legacy rows that predate
 * the field. Corrupt rows degrade to 0 like the previous groups_json parse. */
function parseTotalGroups(resultRow: SimilarityResultRow): number {
  try {
    const stats = JSON.parse(resultRow.stats_json) as { totalGroups?: unknown }
    if (
      typeof stats.totalGroups === 'number' &&
      Number.isInteger(stats.totalGroups) &&
      stats.totalGroups >= 0
    ) {
      return stats.totalGroups
    }
  } catch {
    // stats_json may be absent on legacy rows; fall through to groups_json.
  }
  try {
    const parsed = JSON.parse(resultRow.groups_json) as { groups?: unknown[] }
    return parsed.groups?.length ?? 0
  } catch {
    return 0
  }
}

/** All per-photo lookups that enrich a raw photo set into CullingAssets. */
interface CullingRichLookup {
  decisions: Map<string, CullingDecisionRow>
  cacheRows: Map<string, MetadataCacheRow>
  outboxByPath: Map<string, MetadataOutboxRow>
  similarityMap: Map<string, string>
  qualityByPhoto: Map<string, CullingAsset['quality']>
  facesByPhoto: Map<string, number[][]>
  analysisMaxByPhoto: Map<string, number>
  peopleByPhoto: Map<string, string[]>
  linkedCounts: Map<string, number>
}

/** Photo row shapes the culling service consumes: the heavy JSON columns are
 * never read here, so the full row, the page projection and the light
 * projection are interchangeable. */
export type CullingPhotoRow = PhotoRow | PhotoPageRow | PhotoProjectionRow

/** Reusable per-session input for `updateState`: photos, their id index, the
 * similarity group index and the xmp-linkage map are all immutable during an
 * update burst, so the IPC handler and the batch/history paths share one
 * cached instance instead of re-reading the whole session per click. */
export interface CullingUpdateContext {
  photos: CullingPhotoRow[]
  groupMap: Map<string, string>
  photoById: Map<string, CullingPhotoRow>
  photosByAssetId: Map<string, CullingPhotoRow[]>
  linkedByXmp: Map<string, CullingPhotoRow[]>
  historySink?: CullingHistoryEntry[]
}

/** Version-keyed cache entry: every field is derived from the latest
 * similarity result (its `resultRow.id` is the version), so the entry is
 * rebuilt atomically when a result is replaced and result ids never mix.
 * `groupIndex` is resolved lazily (the groups_json fallback needs the photos
 * row set); the analysis maps are populated by the first session-wide build.
 * A short TTL bounds staleness from background quality/face analyses. */
interface SessionLookupEntry {
  resultRow: SimilarityResultRow | undefined
  similarityMap: Map<string, string>
  groupIndex: Map<string, string>
  groupIndexResolved: boolean
  analysesLoaded: boolean
  qualityByPhoto: Map<string, CullingAsset['quality']>
  facesByPhoto: Map<string, number[][]>
  analysisMaxByPhoto: Map<string, number>
  peopleByPhoto: Map<string, string[]>
  /** Cached groups count (see `parseTotalGroups`), resolved lazily on the
   * first summary read and keyed to the entry's result version: a result
   * replace rebuilds the entry atomically, so a stale count can never be
   * served. The count only depends on the result row, never on culling
   * decisions, so caching it does not stale the badge counts. */
  groupCount: number
  groupCountResolved: boolean
  expiresAt: number
}

/** TTL-cached update context; `groupMap`/`linkedByXmp` are filled lazily so
 * the photo load and the stale-id validation can run before any similarity
 * read (see `ensureUpdateExtras`). `groupMapResultId` pins the group index
 * to the similarity result version it was built from: a result replace
 * switches the id and forces a rebuild, so update clicks never write group
 * ids of an earlier result. `refreshed` bounds the fresh-read fallback for
 * photo misses (see `refreshSessionUpdateContext`) to once per TTL window. */
interface SessionUpdateEntry {
  photos: CullingPhotoRow[]
  photoById: Map<string, CullingPhotoRow>
  photosByAssetId: Map<string, CullingPhotoRow[]>
  groupMap: Map<string, string> | undefined
  groupMapResultId: number | undefined
  linkedByXmp: Map<string, CullingPhotoRow[]> | undefined
  refreshed: boolean
  expiresAt: number
}

type LookupMode = 'session' | 'page'

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

  /** Version-keyed per-session lookup cache (see `SessionLookupEntry`). The
   * main process is single-threaded over synchronous better-sqlite3, so a
   * plain Map is safe without locks. */
  private sessionLookupCache = new Map<string, SessionLookupEntry>()
  /** Session-scoped update context, reused across `update` clicks within a
   * short window (see `SessionUpdateEntry`). */
  private sessionUpdateCache = new Map<string, SessionUpdateEntry>()
  private static readonly LOOKUP_TTL_MS = 5_000
  private static readonly LOOKUP_CACHE_MAX = 8
  private static readonly UPDATE_TTL_MS = 5_000
  private static readonly UPDATE_CACHE_MAX = 8

  list(
    sessionId: string,
    scope: CullingScope,
    filters?: CullingFilters,
    requestedGroupId?: string,
  ): CullingAsset[] {
    const photos = this.photoRepo.getBySession(sessionId)
    const lookup = this.buildRichLookup(photos, sessionId, 'session')
    return this.filterVisible(
      this.assembleAssets(photos, lookup),
      scope,
      filters,
      requestedGroupId,
    )
  }

  /**
   * Paginated counterpart of `list()`. Only the current page's photo subset is
   * enriched with decisions/cache/outbox/quality/faces/people; the heavy JSON
   * columns are skipped via the light projection. Filters that can be expressed
   * in SQL (pick state, rating, color label, quality status, similarity group
   * membership) are pushed down to keep pages full. `total` is exact for pushed
   * filters; approximate when a filter (e.g. `metadataConflictOnly`) is only
   * applied after assembly.
   *
   * Pagination is grouped by logical asset (photos sharing an `asset_id`, e.g.
   * RAW+JPEG variants), so an asset never spans two pages and
   * `variantCount`/`linkedVariantCount` stay correct. `afterRowId` is the asset
   * cursor returned as `nextRowId` by the previous page: the first `rowid` of
   * its last asset group. The renderer only round-trips the cursor.
   */
  listPage(
    sessionId: string,
    scope: CullingScope,
    filters?: CullingFilters,
    requestedGroupId?: string,
    afterRowId?: number,
    limit = 200,
  ): CullingPage {
    const { photos, cursor } = this.pagePhotosQuery(
      sessionId,
      scope,
      filters,
      requestedGroupId,
      afterRowId,
      limit,
    )
    const lookup = this.buildRichLookup(photos, sessionId, 'page')
    const assets = this.filterVisible(
      this.assembleAssets(photos, lookup),
      scope,
      filters,
      requestedGroupId,
    )
    const total = this.countForScope(
      sessionId,
      scope,
      filters,
      requestedGroupId,
      lookup.similarityMap,
    )
    return { assets, nextRowId: cursor, total }
  }

  /** Two-step asset-grouped keyset page shared by all three scopes:
   *  1. fetch up to `limit` asset groups (ordered by their first rowid,
   *     `first_rowid > afterRowId`), applying the scope filter to the photos
   *     that build the groups;
   *  2. fetch every row of those groups, so a page always contains whole
   *     assets.
   * `afterRowId` here is the previous page's `nextRowId`, i.e. the first
   * rowid of its last asset group. `cursor` is that same value for the
   * current page: the group query's `first_rowid` of its last group — never a
   * value derived from the loaded rows, whose minimum rowid may belong to a
   * variant that did not match the predicate (re-deriving it would re-select
   * the group on the next page and duplicate the asset across pages). */
  private pagePhotosQuery(
    sessionId: string,
    scope: CullingScope,
    filters: CullingFilters | undefined,
    requestedGroupId: string | undefined,
    afterRowId: number | undefined,
    limit: number,
  ): { photos: PhotoPageRow[]; cursor: number | null } {
    if (scope === 'filtered') {
      const { sql, params } = this.buildFilteredWhere(sessionId, filters)
      const groups = this.db.prepare(`
        SELECT COALESCE(p.asset_id, p.id) AS gid, MIN(p.rowid) AS first_rowid
        FROM photos p
        LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
        LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
        WHERE ${sql}
        GROUP BY COALESCE(p.asset_id, p.id)
        HAVING MIN(p.rowid) > ?
        ORDER BY first_rowid
        LIMIT ?
      `).all(...params, afterRowId ?? 0, limit) as Array<{
        gid: string
        first_rowid: number
      }>
      return {
        photos: this.loadAssetRows(sessionId, groups),
        cursor: groups.length > 0 ? groups[groups.length - 1].first_rowid : null,
      }
    }
    if (scope === 'similarity_group') {
      const similarity = this.buildSimilarityClause(sessionId, requestedGroupId)
      if (similarity) {
        const groups = this.db.prepare(`
          SELECT COALESCE(p.asset_id, p.id) AS gid, MIN(p.rowid) AS first_rowid
          FROM photos p
          WHERE p.session_id = ? AND ${similarity.sql} AND ${this.preferredRowPredicate()}
          GROUP BY COALESCE(p.asset_id, p.id)
          HAVING MIN(p.rowid) > ?
          ORDER BY first_rowid
          LIMIT ?
        `).all(sessionId, ...similarity.params, afterRowId ?? 0, limit) as Array<{
          gid: string
          first_rowid: number
        }>
        return {
          photos: this.loadAssetRows(sessionId, groups),
          cursor: groups.length > 0 ? groups[groups.length - 1].first_rowid : null,
        }
      }
    }
    const { rows, cursor } = this.photoRepo.getAssetPage(sessionId, afterRowId, limit)
    return { photos: rows, cursor }
  }

  /** Fetches every row of the given asset groups (chunked to stay below
   * SQLite's parameter limit). */
  private loadAssetRows(
    sessionId: string,
    groups: Array<{ gid: string; first_rowid: number }>,
  ): PhotoPageRow[] {
    if (groups.length === 0) return []
    const rows: PhotoPageRow[] = []
    for (let index = 0; index < groups.length; index += 800) {
      const chunk = groups.slice(index, index + 800).map(group => group.gid)
      rows.push(...this.db.prepare(`
        SELECT ${PHOTO_PAGE_COLUMNS}
        FROM photos p
        WHERE p.session_id = ? AND COALESCE(p.asset_id, p.id) IN (${chunk.map(() => '?').join(',')})
        ORDER BY p.rowid
      `).all(sessionId, ...chunk) as PhotoPageRow[])
    }
    return rows
  }

  /** SQL predicate restricting filter-pushdown queries to the preferred row of
   * each asset group: RAW variants first (same extension list as the JS-side
   * `assembleAssets` preference), then the lowest rowid. Filters are evaluated
   * against this preferred row so the SQL page/count and the JS
   * `filterVisible` safety net always agree on which assets match — a
   * non-preferred JPEG that hits a predicate no longer selects its asset
   * while the preferred RAW does not. The predicate is a no-op for ungrouped
   * photos (gid = id ⇒ the subquery returns the row itself). */
  private preferredRowPredicate(): string {
    return `p.id = (
      SELECT p2.id FROM photos p2
      WHERE p2.session_id = p.session_id
        AND COALESCE(p2.asset_id, p2.id) = COALESCE(p.asset_id, p.id)
      ORDER BY CASE WHEN ${RAW_EXTENSION_LIKE_SQL} THEN 1 ELSE 0 END DESC, p2.rowid
      LIMIT 1
    )`
  }

  /** Exact superset of `matchesFilters` minus `metadataConflictOnly` (which
   * depends on the XMP sidecar path computed in JS). The page-level JS filter
   * still runs afterwards as the source of truth. The predicate applies to
   * the photos that build asset groups; the page cursor lives in the group
   * query's HAVING clause instead. */
  private buildFilteredWhere(
    sessionId: string,
    filters: CullingFilters | undefined,
  ): { sql: string; params: unknown[] } {
    const clauses: string[] = ['p.session_id = ?']
    const params: unknown[] = [sessionId]
    if (!filters) return { sql: clauses.join(' AND '), params }
    if (filters.unreviewedOnly) {
      clauses.push("COALESCE(d.decision, 'pending') = 'pending'")
    }
    if (filters.pickStates?.length) {
      const decisions = filters.pickStates.map(state =>
        state === 'picked' ? 'keep' : state === 'rejected' ? 'reject' : 'pending')
      clauses.push(`COALESCE(d.decision, 'pending') IN (${decisions.map(() => '?').join(',')})`)
      params.push(...decisions)
    }
    if (filters.ratings?.length) {
      clauses.push(`COALESCE(d.rating, c.rating, 0) IN (${filters.ratings.map(() => '?').join(',')})`)
      params.push(...filters.ratings)
    }
    if (filters.colorLabels?.length) {
      clauses.push(
        `COALESCE(NULLIF(d.color_label, ''), NULLIF(c.label, ''), 'None') IN (${filters.colorLabels.map(() => '?').join(',')})`,
      )
      params.push(...filters.colorLabels)
    }
    if (filters.qualityStatus === 'analysed' || filters.qualityStatus === 'failed') {
      // json_valid() guards against historical rows whose result_json is not
      // valid JSON: json_extract() would otherwise raise a malformed-JSON
      // SQLite error and fail the whole page query.
      clauses.push(`json_extract(COALESCE((
        SELECT a3.result_json
        FROM asset_analysis a3
        WHERE a3.asset_file_id = p.asset_file_id
          AND a3.analysis_type = 'technical_quality'
          AND json_valid(a3.result_json)
        ORDER BY a3.updated_at DESC
        LIMIT 1
      ), '{}'), '$.status') = ?`)
      params.push(filters.qualityStatus === 'analysed' ? 'succeeded' : 'failed')
    }
    if (filters.qualityStatus === 'unanalysed') {
      // Only a row with valid JSON counts as analysed; a malformed result_json
      // is treated as "no quality result" by the JS layer, so the NOT EXISTS
      // guard must mirror that (see the analysed/failed branch above).
      clauses.push(`NOT EXISTS (
        SELECT 1 FROM asset_analysis a3
        WHERE a3.asset_file_id = p.asset_file_id
          AND a3.analysis_type = 'technical_quality'
          AND json_valid(a3.result_json)
      )`)
    }
    clauses.push(this.preferredRowPredicate())
    return { sql: clauses.join(' AND '), params }
  }

  /** Similarity-group membership as a SQL predicate. Returns null when the
   * group id cannot be parsed, in which case the page is filtered in JS via
   * the similarity map (still exact, possibly under-filled pages). */
  private buildSimilarityClause(
    sessionId: string,
    requestedGroupId: string | undefined,
  ): { sql: string; params: unknown[] } | null {
    if (requestedGroupId) {
      const separator = requestedGroupId.lastIndexOf(':')
      const resultId = separator > 0 ? Number(requestedGroupId.slice(0, separator)) : Number.NaN
      const groupIndex = separator > 0 ? Number(requestedGroupId.slice(separator + 1)) : Number.NaN
      if (!Number.isInteger(resultId) || !Number.isInteger(groupIndex)) return null
      return {
        sql: `EXISTS (
          SELECT 1 FROM similarity_result_members srm
          WHERE srm.result_id = ? AND srm.group_index = ? AND srm.session_id = ?
            AND srm.photo_id = p.id
        )`,
        params: [resultId, groupIndex, sessionId],
      }
    }
    // Precomputed threshold tiers share the same table (marker in stats_json,
    // see similarity-result.repo.ts); MAX(id) alone would pick the newest
    // tier instead of the analysis/recluster row that getLatest resolves to,
    // so the JS-side similarity map and the SQL predicate stay aligned.
    return {
      sql: `EXISTS (
        SELECT 1 FROM similarity_result_members srm
        WHERE srm.session_id = ? AND srm.photo_id = p.id
          AND srm.result_id = (
            SELECT MAX(id) FROM similarity_results
            WHERE session_id = ? AND stats_json NOT LIKE '%"precomputed":true%'
          )
      )`,
      params: [sessionId, sessionId],
    }
  }

  /** Logical-asset count for the scope/filters, so `total` matches the number
   * of entries the filmstrip shows once all pages are loaded (one per asset,
   * not per physical photo row). */
  private countForScope(
    sessionId: string,
    scope: CullingScope,
    filters: CullingFilters | undefined,
    requestedGroupId: string | undefined,
    similarityMap: Map<string, string>,
  ): number {
    if (scope === 'similarity_group') {
      const similarity = this.buildSimilarityClause(sessionId, requestedGroupId)
      if (similarity) {
        const row = this.db.prepare(`
          SELECT COUNT(*) AS count
          FROM (SELECT COALESCE(p.asset_id, p.id) AS gid
                FROM photos p
                WHERE p.session_id = ? AND ${similarity.sql}
                  AND ${this.preferredRowPredicate()}
                GROUP BY gid)
        `).get(sessionId, ...similarity.params) as { count: number } | undefined
        return row?.count ?? 0
      }
      // Unparseable group id: no SQL predicate; count via the JS similarity
      // map (distinct member photo ids).
      if (requestedGroupId) {
        let count = 0
        for (const groupId of similarityMap.values()) {
          if (groupId === requestedGroupId) count++
        }
        return count
      }
      return similarityMap.size
    }
    if (scope === 'filtered') {
      const { sql, params } = this.buildFilteredWhere(sessionId, filters)
      const row = this.db.prepare(`
        SELECT COUNT(*) AS count
        FROM (SELECT COALESCE(p.asset_id, p.id) AS gid
              FROM photos p
              LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
              LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
              WHERE ${sql}
              GROUP BY gid)
      `).get(...params) as { count: number } | undefined
      return row?.count ?? 0
    }
    return this.photoRepo.countAssetsBySession(sessionId)
  }

  private withChunkedIds<T>(ids: string[], query: (chunk: string[]) => T[]): T[] {
    const rows: T[] = []
    for (let index = 0; index < ids.length; index += 800) {
      rows.push(...query(ids.slice(index, index + 800)))
    }
    return rows
  }

  private loadOutboxByPaths(
    sessionId: string,
    xmpPaths: string[],
  ): Map<string, MetadataOutboxRow> {
    const rows = this.withChunkedIds([...new Set(xmpPaths)], chunk => this.db.prepare(`
      SELECT o.*
      FROM metadata_outbox o
      JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
      WHERE os.session_id = ? AND o.xmp_path IN (${chunk.map(() => '?').join(',')})
    `).all(sessionId, ...chunk) as MetadataOutboxRow[])
    return new Map(rows.map(row => [row.xmp_path, row]))
  }

  private loadQualityByPhoto(
    photos: CullingPhotoRow[],
  ): Map<string, CullingAsset['quality']> {
    const qualityByPhoto = new Map<string, CullingAsset['quality']>()
    if (photos.length === 0) return qualityByPhoto
    const qualityRows = this.withChunkedIds(photos.map(photo => photo.id), chunk => this.db.prepare(`
      SELECT p.id AS requested_photo_id, aa.result_json
      FROM photos p
      JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
      WHERE aa.analysis_type = 'technical_quality'
        AND p.id IN (${chunk.map(() => '?').join(',')})
      ORDER BY aa.updated_at DESC
    `).all(...chunk) as Array<{
      requested_photo_id: string
      result_json: string
    }>)
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
    return qualityByPhoto
  }

  private loadFaces(
    photos: CullingPhotoRow[],
    sessionId: string,
    mode: LookupMode,
  ): { facesByPhoto: Map<string, number[][]>; analysisMaxByPhoto: Map<string, number> } {
    const faceRows = mode === 'session'
      ? this.db.prepare(`
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
      : this.withChunkedIds(photos.map(photo => photo.id), chunk => this.db.prepare(`
          SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
          FROM face_observations
          WHERE session_id = ? AND photo_id IN (${chunk.map(() => '?').join(',')})
          ORDER BY id
        `).all(sessionId, ...chunk) as Array<{
          photo_id: string
          bbox_x: number
          bbox_y: number
          bbox_w: number
          bbox_h: number
          analysis_signature: string
        }>)
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
    return { facesByPhoto, analysisMaxByPhoto }
  }

  private loadPeople(
    photos: CullingPhotoRow[],
    sessionId: string,
    mode: LookupMode,
  ): Map<string, string[]> {
    const personRows = mode === 'session'
      ? this.db.prepare(`
          SELECT pp.photo_id, p.name
          FROM person_photos pp
          JOIN persons p ON p.id = pp.person_id
          WHERE pp.session_id = ?
          ORDER BY p.name
        `).all(sessionId) as Array<{ photo_id: string; name: string }>
      : this.withChunkedIds(photos.map(photo => photo.id), chunk => this.db.prepare(`
          SELECT pp.photo_id, p.name
          FROM person_photos pp
          JOIN persons p ON p.id = pp.person_id
          WHERE pp.session_id = ? AND pp.photo_id IN (${chunk.map(() => '?').join(',')})
          ORDER BY p.name
        `).all(sessionId, ...chunk) as Array<{ photo_id: string; name: string }>)
    const peopleByPhoto = new Map<string, string[]>()
    for (const person of personRows) {
      const names = peopleByPhoto.get(person.photo_id) ?? []
      if (!names.includes(person.name)) names.push(person.name)
      peopleByPhoto.set(person.photo_id, names)
    }
    return peopleByPhoto
  }

  private buildRichLookup(
    photos: CullingPhotoRow[],
    sessionId: string,
    mode: LookupMode,
  ): CullingRichLookup {
    const photoIds = photos.map(photo => photo.id)
    const decisions = new Map(
      (mode === 'session'
        ? this.cullingDecisionRepo.getBySession(sessionId)
        : this.cullingDecisionRepo.getByPhotoIds(sessionId, photoIds))
        .map(row => [row.photo_id, row]),
    )
    const cacheRows = new Map(
      this.metadataCacheRepo.getBatch(photoIds)
        .map(row => [row.photo_id, row]),
    )
    const outboxByPath = mode === 'session'
      ? new Map(
        this.metadataOutboxRepo.getBySession(sessionId).map(row => [row.xmp_path, row]),
      )
      : this.loadOutboxByPaths(sessionId, photos.map(photo => getXmpSidecarPath(photo.filepath)))
    const similarityMap = this.getLatestSimilarityMap(sessionId)
    // The session-wide analysis tables (quality/faces/people) are only
    // rewritten by background analyses, so session mode reuses the
    // version-keyed cache instead of re-reading all of them per call; page
    // mode keeps its per-page scoped queries.
    const sessionLookup = this.getSessionLookup(sessionId)
    let qualityByPhoto: Map<string, CullingAsset['quality']>
    let facesByPhoto: Map<string, number[][]>
    let analysisMaxByPhoto: Map<string, number>
    let peopleByPhoto: Map<string, string[]>
    if (mode === 'session') {
      if (!sessionLookup.analysesLoaded) {
        sessionLookup.analysesLoaded = true
        sessionLookup.qualityByPhoto = this.loadQualityByPhoto(photos)
        const faces = this.loadFaces(photos, sessionId, 'session')
        sessionLookup.facesByPhoto = faces.facesByPhoto
        sessionLookup.analysisMaxByPhoto = faces.analysisMaxByPhoto
        sessionLookup.peopleByPhoto = this.loadPeople(photos, sessionId, 'session')
      }
      qualityByPhoto = sessionLookup.qualityByPhoto
      facesByPhoto = sessionLookup.facesByPhoto
      analysisMaxByPhoto = sessionLookup.analysisMaxByPhoto
      peopleByPhoto = sessionLookup.peopleByPhoto
    } else {
      qualityByPhoto = this.loadQualityByPhoto(photos)
      const faces = this.loadFaces(photos, sessionId, 'page')
      facesByPhoto = faces.facesByPhoto
      analysisMaxByPhoto = faces.analysisMaxByPhoto
      peopleByPhoto = this.loadPeople(photos, sessionId, 'page')
    }
    const linkedCounts = new Map<string, number>()
    for (const photo of photos) {
      const xmpPath = getXmpSidecarPath(photo.filepath)
      linkedCounts.set(xmpPath, (linkedCounts.get(xmpPath) ?? 0) + 1)
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
    return {
      decisions,
      cacheRows,
      outboxByPath,
      similarityMap,
      qualityByPhoto,
      facesByPhoto,
      analysisMaxByPhoto,
      peopleByPhoto,
      linkedCounts,
    }
  }

  private assembleAssets(
    photos: CullingPhotoRow[],
    lookup: CullingRichLookup,
  ): CullingAsset[] {
    const {
      decisions,
      cacheRows,
      outboxByPath,
      similarityMap,
      qualityByPhoto,
      facesByPhoto,
      analysisMaxByPhoto,
      peopleByPhoto,
      linkedCounts,
    } = lookup
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

    // Group once by logical asset id (single pass) instead of filtering the
    // whole asset array per group (O(n²) on large sessions).
    const assetsByAssetId = new Map<string, CullingAsset[]>()
    for (const asset of assets) {
      const assetId = asset.photo.assetId ?? `photo:${asset.photo.id}`
      const variants = assetsByAssetId.get(assetId)
      if (variants) variants.push(asset)
      else assetsByAssetId.set(assetId, [asset])
    }
    return [...assetsByAssetId.values()].map(variants => {
      const preferred = variants.find(candidate =>
        isPreferredRawVariant(candidate.photo.filename),
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
  }

  /** Final safety net on top of the SQL pushdown. For pushed-down filters
   * (pick/rating/label/quality/similarity) the SQL predicate already operates
   * on the preferred row, so this JS pass is expected to always pass; the
   * non-pushdown `metadataConflictOnly` filter is applied here. */
  private filterVisible(
    assets: CullingAsset[],
    scope: CullingScope,
    filters: CullingFilters | undefined,
    requestedGroupId?: string,
  ): CullingAsset[] {
    return assets.filter(asset => {
      if (scope === 'similarity_group') {
        if (!asset.similarityGroupId) return false
        if (requestedGroupId && asset.similarityGroupId !== requestedGroupId) return false
      }
      return scope !== 'filtered' || this.matchesFilters(asset, filters)
    })
  }

  /** Cached `updateState` context (see `SessionUpdateEntry`); the IPC update
   * handler reuses it so a click burst never re-reads the whole session. */
  getUpdateContext(sessionId: string): CullingUpdateContext {
    const entry = this.getSessionUpdateContext(sessionId)
    this.ensureUpdateExtras(entry, sessionId)
    return {
      photos: entry.photos,
      photoById: entry.photoById,
      photosByAssetId: entry.photosByAssetId,
      groupMap: entry.groupMap!,
      linkedByXmp: entry.linkedByXmp!,
    }
  }

  /** Photos + id index of the session, TTL-cached. The update paths use it so
   * a click burst stops re-reading the whole session (heavy JSON columns
   * skipped via the light projection) on every keystroke. */
  private getSessionUpdateContext(sessionId: string): SessionUpdateEntry {
    const now = Date.now()
    const cached = this.sessionUpdateCache.get(sessionId)
    if (cached && cached.expiresAt > now) return cached
    const photos = this.loadSessionPhotos(sessionId)
    const entry: SessionUpdateEntry = {
      photos,
      photoById: new Map(photos.map(photo => [photo.id, photo])),
      photosByAssetId: buildPhotosByAssetIndex(photos),
      groupMap: undefined,
      groupMapResultId: undefined,
      linkedByXmp: undefined,
      refreshed: false,
      expiresAt: now + CullingService.UPDATE_TTL_MS,
    }
    this.sessionUpdateCache.set(sessionId, entry)
    this.pruneSessionUpdateCache()
    return entry
  }

  /** Fresh-read fallback for a TTL-cached update context that missed a photo
   * id: the indexer's add/delete can be invisible to the cache, so one fresh
   * read per TTL window is attempted before the caller gives up (a newly
   * imported photo must never be rejected, a really deleted one still is on
   * the second check). The group index, xmp linkage and the session lookup
   * are invalidated with the photo set so they rebuild against the new rows
   * on the next `ensureUpdateExtras`. */
  private refreshSessionUpdateContext(sessionId: string, entry: SessionUpdateEntry): void {
    if (entry.refreshed) return
    const photos = this.loadSessionPhotos(sessionId)
    entry.photos = photos
    entry.photoById = new Map(photos.map(photo => [photo.id, photo]))
    entry.photosByAssetId = buildPhotosByAssetIndex(photos)
    entry.groupMap = undefined
    entry.groupMapResultId = undefined
    entry.linkedByXmp = undefined
    entry.refreshed = true
    // The group index may have been resolved against the previous photo set
    // (groups_json fallback), so the session lookup is rebuilt from scratch.
    this.sessionLookupCache.delete(sessionId)
  }

  /** Lazily fills the similarity group index and the xmp-linkage map of a
   * cached update context. The group index is keyed by similarity result
   * version (`getSessionLookup` resolves the latest row): every access
   * re-checks the version, so a result replace rebuilds the map instead of
   * writing orphan `${oldResultId}:${i}` group ids. The xmp linkage only
   * depends on the photo set and is rebuilt together with it (see
   * `refreshSessionUpdateContext`). Kept separate from the photos load so
   * callers can validate photo ids before any similarity read, and so the
   * O(n) xmp-sidecar scan runs once per entry/version instead of per click. */
  private ensureUpdateExtras(entry: SessionUpdateEntry, sessionId: string): void {
    const lookup = this.getSessionLookup(sessionId)
    if (entry.groupMap !== undefined && entry.groupMapResultId === lookup.resultRow?.id) {
      return
    }
    entry.groupMap = this.buildPhotoGroupIndex(entry.photos, sessionId, lookup)
    entry.groupMapResultId = lookup.resultRow?.id
    const linkedByXmp = new Map<string, CullingPhotoRow[]>()
    for (const photo of entry.photos) {
      const xmpPath = getXmpSidecarPath(photo.filepath)
      const linked = linkedByXmp.get(xmpPath) ?? []
      linked.push(photo)
      linkedByXmp.set(xmpPath, linked)
    }
    entry.linkedByXmp = linkedByXmp
  }

  private pruneSessionUpdateCache(): void {
    const now = Date.now()
    for (const [sessionId, entry] of this.sessionUpdateCache) {
      if (entry.expiresAt <= now) this.sessionUpdateCache.delete(sessionId)
    }
    while (this.sessionUpdateCache.size > CullingService.UPDATE_CACHE_MAX) {
      const oldest = this.sessionUpdateCache.keys().next().value
      if (oldest === undefined) break
      this.sessionUpdateCache.delete(oldest)
    }
  }

  private loadSessionPhotos(sessionId: string): CullingPhotoRow[] {
    // The light projection is used on the hot paths; the full-row fallback
    // keeps unit-test doubles that only expose getBySession working.
    return typeof this.photoRepo.getBySessionProjection === 'function'
      ? this.photoRepo.getBySessionProjection(sessionId)
      : this.photoRepo.getBySession(sessionId)
  }

  updateState(
    sessionId: string,
    photoId: string,
    expectedRevision: number,
    patch: CullingUpdatePatch,
    context?: CullingUpdateContext,
  ): CullingUpdateResult {
    this.validatePatch(patch)
    const entry = this.getSessionUpdateContext(sessionId)
    let photos = context?.photos ?? entry.photos
    let photoById = context?.photoById ?? entry.photoById
    let contextGroupMap = context?.groupMap
    let contextLinkedByXmp = context?.linkedByXmp
    let contextPhotosByAssetId = context?.photosByAssetId
    let target = photoById.get(photoId) ?? photos.find(photo => photo.id === photoId)
    if (!target) {
      // The TTL-cached photo set can miss photos the indexer just added, so
      // one fresh read per window is attempted before giving up (see
      // refreshSessionUpdateContext). A stale caller-supplied context is
      // dropped in favor of the refreshed entry.
      this.refreshSessionUpdateContext(sessionId, entry)
      photos = entry.photos
      photoById = entry.photoById
      contextGroupMap = undefined
      contextLinkedByXmp = undefined
      contextPhotosByAssetId = undefined
      target = photoById.get(photoId) ?? photos.find(photo => photo.id === photoId)
      if (!target) throw codedError('CULLING_PHOTO_NOT_IN_SESSION')
    }

    const currentRow = this.cullingDecisionRepo.getDecision(sessionId, photoId)
    const currentRevision = currentRow?.revision ?? 0
    if (currentRevision !== expectedRevision) {
      throw codedError('CULLING_REVISION_CONFLICT', {
        expected: expectedRevision,
        current: currentRevision,
      })
    }

    const targetXmpPath = getXmpSidecarPath(target.filepath)
    const changesSharedMetadata =
      patch.rating !== undefined || patch.colorLabel !== undefined
    // A complete caller-supplied context (IPC/batch) already went through
    // ensureUpdateExtras, so the per-click version check would be a
    // redundant similarity read; it runs only on the direct-call paths and
    // after a fresh-read fallback dropped the context maps above.
    if (contextGroupMap === undefined) this.ensureUpdateExtras(entry, sessionId)
    const photosByAssetId = contextPhotosByAssetId ?? entry.photosByAssetId
    const affectedById = new Map<string, CullingPhotoRow>()
    if (patch.pickState !== undefined && target.asset_id) {
      // One map lookup instead of an O(n) scan of the session's photos per
      // update; the asset→photos index is built once per cached context.
      for (const photo of photosByAssetId.get(target.asset_id) ?? []) {
        affectedById.set(photo.id, photo)
      }
    } else {
      affectedById.set(target.id, target)
    }
    if (changesSharedMetadata) {
      // The xmp→photos index is built once per cached context instead of an
      // O(n) sidecar scan per click.
      for (const photo of (contextLinkedByXmp ?? entry.linkedByXmp!).get(targetXmpPath) ?? []) {
        affectedById.set(photo.id, photo)
      }
    }
    const affectedPhotos = [...affectedById.values()]
    const pickTargets = patch.pickState !== undefined && target.asset_id
      ? new Set((photosByAssetId.get(target.asset_id) ?? []).map(photo => photo.id))
      : new Set([target.id])
    const groupMap = contextGroupMap ?? entry.groupMap!
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
    if (uniqueIds.length === 0) throw codedError('CULLING_EMPTY_SELECTION')
    const entry = this.getSessionUpdateContext(sessionId)
    // Validate the photo ids against the cached index before any similarity
    // read (see ensureUpdateExtras). A miss may be a photo the indexer just
    // added (invisible to the TTL cache), so one fresh read is attempted
    // before the batch is rejected (see refreshSessionUpdateContext).
    if (uniqueIds.some(photoId => !entry.photoById.has(photoId))) {
      this.refreshSessionUpdateContext(sessionId, entry)
      if (uniqueIds.some(photoId => !entry.photoById.has(photoId))) {
        throw codedError('CULLING_PHOTOS_NOT_IN_SESSION')
      }
    }
    this.ensureUpdateExtras(entry, sessionId)
    const photos = entry.photos
    const photoById = entry.photoById
    const groupMap = entry.groupMap!
    const linkedByXmp = entry.linkedByXmp!
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
    // One IN query preloads the decision rows of every operation target
    // instead of a per-operation getDecision inside the transaction (an
    // N+1 of single-row queries). The preload runs in the same synchronous
    // tick as the transaction, and each photo is written at most once per
    // batch (the operation ids are unique per logical asset / xmp path), so
    // the pre-read revisions cannot go stale between preload and upsert.
    const currentRows = new Map(
      this.cullingDecisionRepo.getByPhotoIds(sessionId, operationIds)
        .map(row => [row.photo_id, row]),
    )
    this.db.transaction(() => {
      for (const photoId of operationIds) {
        const current = currentRows.get(photoId)
        results.push(this.updateState(
          sessionId,
          photoId,
          current?.revision ?? 0,
          patch,
          {
            photos,
            groupMap,
            photoById,
            photosByAssetId: entry.photosByAssetId,
            linkedByXmp,
            historySink: historyEntries,
          },
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
      if (!operation) throw new Error('CULLING_HISTORY_NOT_FOUND')
      if (operation.undone !== (direction === 'redo')) {
        throw new Error(direction === 'undo' ? 'CULLING_HISTORY_ALREADY_UNDONE' : 'CULLING_HISTORY_NOT_UNDONE')
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
    // ADR-017: internal-invariant diagnostic — a corrupted history payload.
    if (unique.size !== entries.length) throw new Error('History command contains duplicate photos')
    for (const entry of entries) this.validatePatch(entry.patch)
    const updateEntry = this.getSessionUpdateContext(sessionId)
    // Same fresh-read fallback as updateState/batchUpdate: a photo the
    // indexer just added can be missing from the TTL-cached photo set.
    if (entries.some(entry => !updateEntry.photoById.has(entry.photoId))) {
      this.refreshSessionUpdateContext(sessionId, updateEntry)
    }
    const photoById = updateEntry.photoById
    const currentRows = new Map(
      this.cullingDecisionRepo.getByPhotoIds(sessionId, entries.map(entry => entry.photoId))
        .map(row => [row.photo_id, row]),
    )
    const cacheRows = new Map(
      this.metadataCacheRepo.getBatch(entries.map(entry => entry.photoId))
        .map(row => [row.photo_id, row]),
    )
    for (const entry of entries) {
      if (!photoById.has(entry.photoId)) throw codedError('CULLING_PHOTO_NOT_IN_SESSION')
      const currentRevision = currentRows.get(entry.photoId)?.revision ?? 0
      if (historyOperationId === undefined && currentRevision !== entry.expectedRevision) {
        throw codedError('CULLING_REVISION_CONFLICT', {
          expected: entry.expectedRevision,
          current: currentRevision,
        })
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
            throw new Error('CULLING_HISTORY_DIVERGED')
          }
        }
      }
    }
    this.ensureUpdateExtras(updateEntry, sessionId)
    const groupMap = updateEntry.groupMap!

    // The outbox is read once per session instead of twice per entry (10k
    // undos would otherwise be 20k single-row queries): rows are keyed by
    // xmp path and reused for the in-transaction syncStatus reads, which all
    // run before queuePhotoValues writes any outbox row (the writes happen
    // after the loop). Test doubles that only expose the per-path `get`
    // fall back to it, preserving their behavior.
    const outboxByPath = typeof this.metadataOutboxRepo.getBySession === 'function'
      ? new Map(this.metadataOutboxRepo.getBySession(sessionId).map(row => [row.xmp_path, row]))
      : null
    const outboxStatus = (xmpPath: string): MetadataSyncStatus =>
      outboxByPath
        ? outboxByPath.get(xmpPath)?.status ?? 'clean'
        : this.metadataOutboxRepo.get(xmpPath)?.status ?? 'clean'

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
          syncStatus: outboxStatus(xmpPath),
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
    // queuePhotoValues wrote the outbox inside the transaction (mergePatch
    // bumps the status to 'pending'), so the preloaded snapshot is refreshed
    // with one more bulk read — the returned statuses must reflect the
    // post-write rows, like the per-path re-reads they replace.
    if (outboxByPath) {
      for (const row of this.metadataOutboxRepo.getBySession(sessionId)) {
        outboxByPath.set(row.xmp_path, row)
      }
    }
    return results.map(result => ({
      ...result,
      syncStatus: outboxByPath
        ? outboxByPath.get(result.xmpPath)?.status ?? result.syncStatus
        : this.metadataOutboxRepo.get(result.xmpPath)?.status ?? result.syncStatus,
      historyOperationId,
    }))
  }

  decideSimilarityGroup(
    sessionId: string,
    groupId: string,
    keepPhotoIds: string[],
  ): CullingUpdateResult[] {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    if (!resultRow) throw new Error('CULLING_NO_SIMILARITY')
    const membership = this.similarityResultRepo.getPhotoGroupMap(sessionId, resultRow.id)
    const groupPhotoIds = [...membership.entries()]
      .filter(([, candidateGroupId]) => candidateGroupId === groupId)
      .map(([photoId]) => photoId)
    if (groupPhotoIds.length < 2) throw new Error('CULLING_GROUP_TOO_SMALL')

    const keepIds = [...new Set(keepPhotoIds)]
    const groupIdSet = new Set(groupPhotoIds)
    if (
      keepIds.length < 1 ||
      keepIds.length >= groupPhotoIds.length ||
      keepIds.some(photoId => !groupIdSet.has(photoId))
    ) {
      throw new Error('CULLING_KEEP_NOT_IN_GROUP')
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

    // Light projection: only id/filepath/filename are needed here, so the
    // heavy metadata/result JSON blobs are skipped.
    const photos = this.photoRepo.getBySessionProjection(sessionId)
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
      const parsedIndex = Number(groupId.split(':').at(-1))
      // Malformed memberships (corrupt legacy rows) must not produce NaN
      // sort keys that destabilize the group ordering.
      const groupIndex = Number.isFinite(parsedIndex) ? parsedIndex : 0
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
    // Light projection: only photo ids feed the decision/cache lookups.
    const photos = this.photoRepo.getBySessionProjection(sessionId)
    const decisions = this.cullingDecisionRepo.getBySession(sessionId)
    const decisionByPhoto = new Map(decisions.map(row => [row.photo_id, row]))
    // The decision and cache reads stay fresh on every call: the renderer
    // refetches the summary after each update/undo/redo and the badge counts
    // must reflect the just-finished write, so the per-session caches are
    // never reused here. Only the cache rows are read through a light
    // projection (photo_id, rating, label): the keywords JSON column that
    // getBatch carries is never needed for counting.
    const cacheByPhoto = this.loadSummaryCacheByPhoto(photos)
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
    // The groups count is derived from the session lookup entry, which is
    // version-keyed by the latest similarity result: stats_json.totalGroups
    // (a small JSON object) replaces the multi-MB groups_json parse, and the
    // result is cached per (session, result id) so a click burst stops
    // re-parsing the payload. A result replace flips the id and rebuilds the
    // entry atomically, so the cached count can never be stale.
    const lookup = this.getSessionLookup(sessionId)
    let totalGroups = 0
    if (lookup.resultRow) {
      if (!lookup.groupCountResolved) {
        lookup.groupCount = parseTotalGroups(lookup.resultRow)
        lookup.groupCountResolved = true
      }
      totalGroups = lookup.groupCount
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

  /** Light photo_metadata_cache projection for `getSummary`: only the
   * rating/label fallbacks of the counting loop are needed, so the heavy
   * keywords JSON column read by `getBatch` is skipped. */
  private loadSummaryCacheByPhoto(
    photos: CullingPhotoRow[],
  ): Map<string, { rating: number; label: string | null }> {
    const cacheByPhoto = new Map<string, { rating: number; label: string | null }>()
    if (photos.length === 0) return cacheByPhoto
    const rows = this.withChunkedIds(photos.map(photo => photo.id), chunk => this.db.prepare(`
      SELECT photo_id, rating, label
      FROM photo_metadata_cache
      WHERE photo_id IN (${chunk.map(() => '?').join(',')})
    `).all(...chunk) as Array<{ photo_id: string; rating: number; label: string | null }>)
    for (const row of rows) cacheByPhoto.set(row.photo_id, row)
    return cacheByPhoto
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
      throw codedError('CULLING_PATCH_INVALID')
    }
    // ADR-017: internal-invariant diagnostics below — the renderer only sends
    // patches it built from the shared constants, so these are bug guards.
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

  /** Drops the session's lookup cache entry so the next list()/listPage()
   * call rebuilds it from fresh database state. Called by background analysis
   * services (quality, face-keyword) when they finish a pass: the cached
   * quality/faces/people maps would otherwise stay stale for the remainder
   * of the TTL window. A missing entry is a no-op, and the rebuild keeps the
   * result-version keying of `getSessionLookup` intact. */
  invalidateSessionLookup(sessionId: string): void {
    this.sessionLookupCache.delete(sessionId)
  }

  /** Latest similarity result row plus the version-keyed lookups derived from
   * it; see `SessionLookupEntry`. The result id is the version: a replace
   * switches it and rebuilds the entry atomically, so cached rows of one
   * result never mix with another. */
  private getSessionLookup(sessionId: string): SessionLookupEntry {
    const resultRow = this.similarityResultRepo.getLatest(sessionId)
    const now = Date.now()
    const cached = this.sessionLookupCache.get(sessionId)
    if (cached && cached.resultRow?.id === resultRow?.id && cached.expiresAt > now) {
      return cached
    }
    const similarityMap = resultRow
      ? this.similarityResultRepo.getPhotoGroupMap(sessionId, resultRow.id)
      : new Map<string, string>()
    const entry: SessionLookupEntry = {
      resultRow,
      similarityMap,
      groupIndex: similarityMap.size > 0 ? similarityMap : new Map(),
      groupIndexResolved: similarityMap.size > 0,
      analysesLoaded: false,
      qualityByPhoto: new Map(),
      facesByPhoto: new Map(),
      analysisMaxByPhoto: new Map(),
      peopleByPhoto: new Map(),
      groupCount: 0,
      groupCountResolved: false,
      expiresAt: now + CullingService.LOOKUP_TTL_MS,
    }
    this.sessionLookupCache.set(sessionId, entry)
    this.pruneSessionLookupCache()
    return entry
  }

  /** Keeps the lookup cache bounded: drops expired entries and, when still
   * over the cap, the oldest session (Map preserves insertion order). */
  private pruneSessionLookupCache(): void {
    const now = Date.now()
    for (const [sessionId, entry] of this.sessionLookupCache) {
      if (entry.expiresAt <= now) this.sessionLookupCache.delete(sessionId)
    }
    while (this.sessionLookupCache.size > CullingService.LOOKUP_CACHE_MAX) {
      const oldest = this.sessionLookupCache.keys().next().value
      if (oldest === undefined) break
      this.sessionLookupCache.delete(oldest)
    }
  }

  private getLatestSimilarityMap(sessionId: string): Map<string, string> {
    return this.getSessionLookup(sessionId).similarityMap
  }

  /** Group index of every photo, resolved once per (session, result version)
   * and reused by every update click: the members table is immutable between
   * result replaces, so the index is rebuilt only on a version change. The
   * caller may pass the already-resolved lookup (see `ensureUpdateExtras`)
   * so the version resolution query runs once instead of twice per build. */
  private buildPhotoGroupIndex(
    photos: CullingPhotoRow[],
    sessionId: string,
    lookup: SessionLookupEntry = this.getSessionLookup(sessionId),
  ): Map<string, string> {
    if (lookup.groupIndexResolved) return lookup.groupIndex
    lookup.groupIndexResolved = true
    const resultRow = lookup.resultRow
    if (!resultRow) return lookup.groupIndex

    // groups_json is DB content; corrupt or structurally unexpected rows
    // degrade to an empty index instead of crashing updateState/batchUpdate.
    let groups: SimilarityGroup[]
    try {
      const parsed = JSON.parse(resultRow.groups_json) as { groups?: SimilarityGroup[] }
      groups = Array.isArray(parsed.groups) ? parsed.groups : []
    } catch {
      groups = []
    }
    const photoIdByPath = new Map(photos.map(photo => [photo.filepath, photo.id]))
    const groupByPhotoId = new Map<string, string>()
    for (let index = 0; index < groups.length; index++) {
      const images = groups[index]?.images
      if (!Array.isArray(images)) continue
      for (const image of images) {
        const photoId = photoIdByPath.get(image.path)
        if (photoId) groupByPhotoId.set(photoId, `${resultRow.id}:${index}`)
      }
    }
    lookup.groupIndex = groupByPhotoId
    return lookup.groupIndex
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
