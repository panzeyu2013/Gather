import * as path from 'path'
import { SettingsService } from '../settings/settings.service'
import type { MetadataReader, MetadataWriter } from '../metadata/metadata-writer.interface'
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

/** Deliverable formats — embedded XMP is read when no sidecar is present */
const DELIVERABLE_EXTENSIONS = new Set([
  '.jpg', '.jpeg', '.tif', '.tiff', '.png',
  '.webp', '.heic', '.heif', '.avif', '.dng',
])

/**
 * Resolves the metadata reader/writer for a photo.
 *
 * Writes are always routed to sidecars (`selectSidecar`) so source images stay
 * untouched; this is the documented contract of the reliability pipeline.
 * `selectForRead` picks the embedded-vs-sidecar source based on format and the
 * (deprecated, read-only) `metadata_write_mode` preference.
 */
@injectable()
export class MetadataWriterRouter {
  private xmpSidecar: XmpSidecarWriter
  private embedded = new EmbeddedWriter()

  constructor(@inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService) {
    this.xmpSidecar = new XmpSidecarWriter(
      () => this.settings.get('capture_one_color_compatibility', 'label_and_urgency'),
    )
  }

  selectForRead(photoPath: string): MetadataReader {
    const mode = this.settings.get('metadata_write_mode', 'auto')
    const ext = path.extname(photoPath).toLowerCase()

    switch (mode) {
      case 'embedded':
        if (this.embedded.supportsFormat(ext)) {
          return this.embedded
        }
        console.warn(`Embedded read not supported for ${ext}, falling back to sidecar`)
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

  /** Workflow writeback is sidecar-only so source images stay untouched. */
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
