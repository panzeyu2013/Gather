import type { ImageDecoder } from './decoder'
import * as path from 'path'

export class DecoderRegistry {
  private decoders: ImageDecoder[] = []

  register(decoder: ImageDecoder): void {
    this.decoders.push(decoder)
  }

  resolve(filePath: string): ImageDecoder {
    const ext = path.extname(filePath).toLowerCase()
    for (const d of this.decoders) {
      if (d.supports(ext)) return d
    }
    throw new Error(`Unsupported file extension: ${ext}`)
  }
}
