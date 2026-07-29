import * as path from 'path'
import { SettingsService } from '../settings/settings.service'
import type { MetadataWriter } from '../metadata/metadata-writer.interface'
import { XmpSidecarWriter } from './xmp-sidecar-writer'
import { EmbeddedWriter } from './embedded-writer'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

/** RAW formats — preserve originals via sidecar (Capture One / Lightroom only read .xmp) */
const RAW_EXTENSIONS = new Set([
  '.cr2', '.cr3',
  '.nef', '.nrw',
  '.arw', '.sr2', '.srf',
  '.raf',
  '.orf',
  '.pef',
  '.rw2', '.rwl',
  '.srw',
  '.iiq',
  '.fff',
  '.3fr',
  '.mos',
  '.x3f',
  '.gpr',
])

/** Deliverable formats — embedded write has broad software compatibility */
const DELIVERABLE_EXTENSIONS = new Set([
  '.jpg', '.jpeg', '.tif', '.tiff', '.png',
  '.webp', '.heic', '.heif', '.avif', '.dng',
])

@injectable()
export class MetadataWriterRouter {
  private xmpSidecar = new XmpSidecarWriter()
  private embedded = new EmbeddedWriter()

  constructor(@inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService) {}

  select(photoPath: string): MetadataWriter {
    const mode = this.settings.get('metadata_write_mode', 'auto')
    const ext = path.extname(photoPath).toLowerCase()

    switch (mode) {
      case 'embedded':
        if (this.embedded.supportsFormat(ext)) {
          return this.embedded
        }
        console.warn(`Embedded mode not supported for ${ext}, falling back to sidecar`)
        return this.xmpSidecar

      case 'sidecar':
        return this.xmpSidecar

      case 'auto':
      default:
        if (RAW_EXTENSIONS.has(ext)) {
          return this.xmpSidecar
        }
        if (DELIVERABLE_EXTENSIONS.has(ext)) {
          return this.embedded
        }
        return this.xmpSidecar
    }
  }

  /** Workflow writeback is intentionally sidecar-only so source images stay untouched. */
  selectSidecar(): MetadataWriter {
    return this.xmpSidecar
  }

  async shutdown(): Promise<void> {
    await Promise.all([
      this.xmpSidecar.shutdown(),
      this.embedded.shutdown(),
    ])
  }
}
