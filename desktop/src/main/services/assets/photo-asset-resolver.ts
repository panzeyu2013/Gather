import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import { SettingsService } from '../settings/settings.service'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'
import { createHash } from 'node:crypto'

function pathDigest(value: string | null): string {
  return createHash('sha256').update(value ?? '').digest('hex').slice(0, 12)
}

export interface ResolvedPhotoAsset {
  photoId: string
  sessionId: string
  assetId: string
  assetFileId: string
  filepath: string
  xmpPath: string
  source: 'legacy' | 'asset'
}

@injectable()
export class PhotoAssetResolver {
  constructor(
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
  ) {}

  resolve(sessionId: string, photoId: string): ResolvedPhotoAsset {
    const row = this.db.prepare(`
      SELECT p.id AS photo_id, p.session_id, p.filepath AS legacy_path,
        p.asset_id, p.asset_file_id, af.normalized_path AS asset_path,
        sb.xmp_path
      FROM photos p
      LEFT JOIN asset_files af ON af.id = p.asset_file_id
      LEFT JOIN sidecar_binding_files sbf ON sbf.file_id = af.id
      LEFT JOIN sidecar_bindings sb ON sb.id = sbf.sidecar_binding_id AND sb.status = 'active'
      WHERE p.id = ? AND p.session_id = ?
      ORDER BY sb.updated_at DESC LIMIT 1
    `).get(photoId, sessionId) as ResolverRow | undefined
    if (!row) throw new Error('Photo does not belong to this workspace')
    const resolved = this.buildResolved(row, this.settings.get('asset_read_mode', 'dual'))
    if (!resolved) throw new Error('Photo Asset migration is incomplete for this photo')
    return resolved
  }

  /**
   * Batched resolve(): one IN query instead of one 5-way JOIN per photo.
   * Rows that the single-photo version would reject (unknown photo, or
   * asset_read_mode='asset' with an incomplete migration) are simply absent
   * from the result — callers treat a missing entry as the single-photo
   * throw and apply their own fallback. Where several active bindings exist
   * for one photo, the newest wins exactly like the single-row
   * ORDER BY sb.updated_at DESC LIMIT 1.
   */
  resolveMany(sessionId: string, photoIds: string[]): Map<string, ResolvedPhotoAsset> {
    const resolved = new Map<string, ResolvedPhotoAsset>()
    if (photoIds.length === 0) return resolved
    const mode = this.settings.get('asset_read_mode', 'dual')
    const seen = new Set<string>()
    // Stay below SQLite's commonly configured parameter limit, mirroring the
    // other repository batch reads.
    for (let index = 0; index < photoIds.length; index += 800) {
      const chunk = photoIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(',')
      const rows = this.db.prepare(`
        SELECT p.id AS photo_id, p.session_id, p.filepath AS legacy_path,
          p.asset_id, p.asset_file_id, af.normalized_path AS asset_path,
          sb.xmp_path
        FROM photos p
        LEFT JOIN asset_files af ON af.id = p.asset_file_id
        LEFT JOIN sidecar_binding_files sbf ON sbf.file_id = af.id
        LEFT JOIN sidecar_bindings sb ON sb.id = sbf.sidecar_binding_id AND sb.status = 'active'
        WHERE p.id IN (${placeholders}) AND p.session_id = ?
        ORDER BY p.id, sb.updated_at DESC
      `).all(...chunk, sessionId) as ResolverRow[]
      for (const row of rows) {
        if (seen.has(row.photo_id)) continue
        seen.add(row.photo_id)
        const asset = this.buildResolved(row, mode)
        if (asset) resolved.set(row.photo_id, asset)
      }
    }
    return resolved
  }

  private buildResolved(row: ResolverRow, mode: string): ResolvedPhotoAsset | null {
    const assetReady = Boolean(row.asset_id && row.asset_file_id && row.asset_path)
    const assetXmpPath = row.xmp_path ?? (row.asset_path ? getXmpSidecarPath(row.asset_path) : null)
    const legacyXmpPath = getXmpSidecarPath(row.legacy_path)
    if (
      mode === 'dual' &&
      assetReady &&
      (row.asset_path !== row.legacy_path || assetXmpPath !== legacyXmpPath)
    ) {
      console.warn('Asset shadow-read mismatch', {
        photoId: row.photo_id,
        pathMismatch: row.asset_path !== row.legacy_path,
        sidecarMismatch: assetXmpPath !== legacyXmpPath,
        legacyPathDigest: pathDigest(row.legacy_path),
        assetPathDigest: pathDigest(row.asset_path),
      })
    }
    if (mode === 'asset' && !assetReady) {
      return null
    }
    const useAsset = mode === 'asset' && assetReady
    return {
      photoId: row.photo_id,
      sessionId: row.session_id,
      assetId: row.asset_id ?? row.photo_id,
      assetFileId: row.asset_file_id ?? row.photo_id,
      filepath: useAsset ? row.asset_path! : row.legacy_path,
      xmpPath: useAsset ? assetXmpPath! : legacyXmpPath,
      source: useAsset ? 'asset' : 'legacy',
    }
  }
}

interface ResolverRow {
  photo_id: string
  session_id: string
  legacy_path: string
  asset_id: string | null
  asset_file_id: string | null
  asset_path: string | null
  xmp_path: string | null
}
