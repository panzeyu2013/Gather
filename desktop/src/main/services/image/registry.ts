import type { ImageDecoder } from './decoder'
import * as path from 'path'

export class DecoderRegistry {
  private decoders: ImageDecoder[] = []

  register(decoder: ImageDecoder): void {
    this.decoders.push(decoder)
  }

  /** All decoders that claim the file extension, in registration order. */
  resolveAll(filePath: string): ImageDecoder[] {
    const ext = path.extname(filePath).toLowerCase()
    const matches = this.decoders.filter(d => d.supports(ext))
    if (matches.length === 0) {
      throw new Error(`Unsupported file extension: ${ext}`)
    }
    return matches
  }
}
