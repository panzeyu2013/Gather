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
    `).get(photoId, sessionId) as {
      photo_id: string
      session_id: string
      legacy_path: string
      asset_id: string | null
      asset_file_id: string | null
      asset_path: string | null
      xmp_path: string | null
    } | undefined
    if (!row) throw new Error('Photo does not belong to this workspace')
    const mode = this.settings.get('asset_read_mode', 'dual')
    const assetReady = Boolean(row.asset_id && row.asset_file_id && row.asset_path)
    const assetXmpPath = row.xmp_path ?? (row.asset_path ? getXmpSidecarPath(row.asset_path) : null)
    const legacyXmpPath = getXmpSidecarPath(row.legacy_path)
    if (
      mode === 'dual' &&
      assetReady &&
      (row.asset_path !== row.legacy_path || assetXmpPath !== legacyXmpPath)
    ) {
      console.warn('Asset shadow-read mismatch', {
        photoId,
        pathMismatch: row.asset_path !== row.legacy_path,
        sidecarMismatch: assetXmpPath !== legacyXmpPath,
        legacyPathDigest: pathDigest(row.legacy_path),
        assetPathDigest: pathDigest(row.asset_path),
      })
    }
    if (mode === 'asset' && !assetReady) {
      throw new Error('Photo Asset migration is incomplete for this photo')
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
