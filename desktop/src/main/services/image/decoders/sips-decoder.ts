import { execFile } from 'child_process'
import { promisify } from 'util'
import * as fs from 'fs'
import * as path from 'path'
import * as os from 'os'
import sharp from 'sharp'
import { IMAGE_CONFIG } from '../image-config'
import type { ImageDecoder, DecodeResult } from '../decoder'

const execFileAsync = promisify(execFile)

function tempJpegPath(): string {
  return path.join(os.tmpdir(), `gather-sips-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`)
}

async function sipsToBuffer(args: string[]): Promise<Buffer> {
  const outPath = tempJpegPath()
  try {
    await execFileAsync('sips', [...args, '--out', outPath])
    return fs.readFileSync(outPath)
  } finally {
    try { fs.unlinkSync(outPath) } catch {}
  }
}

export class SipsDecoder implements ImageDecoder {
  readonly name = 'Sips (Apple RAW)'

  private static RAW_EXTENSIONS = new Set(IMAGE_CONFIG.sips.rawExtensions)

  supports(ext: string): boolean {
    return SipsDecoder.RAW_EXTENSIONS.has(ext)
  }

  async getPreview(path: string, _maxDimension?: number): Promise<DecodeResult> {
    const maxDim = _maxDimension ?? 1920
    const buffer = await sipsToBuffer([
      '-Z', String(maxDim),
      '-s', 'format', 'jpeg',
      path,
    ])
    const metadata = await sharp(buffer).metadata()
    return {
      buffer,
      format: 'jpeg',
      width: metadata.width ?? 0,
      height: metadata.height ?? 0,
    }
  }

  async getThumbnail(path: string, size: number): Promise<DecodeResult> {
    const buffer = await sipsToBuffer([
      '-Z', String(size),
      '-s', 'format', 'jpeg',
      path,
    ])
    const metadata = await sharp(buffer).metadata()
    return {
      buffer,
      format: 'jpeg',
      width: metadata.width ?? size,
      height: metadata.height ?? size,
    }
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const { stdout } = await execFileAsync('sips', [
      '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'orientation', path,
    ])
    let w = parseInt(stdout.match(/pixelWidth: (\d+)/)?.[1] ?? '0', 10)
    let h = parseInt(stdout.match(/pixelHeight: (\d+)/)?.[1] ?? '0', 10)
    const orientation = parseInt(stdout.match(/orientation: (\d+)/)?.[1] ?? '1', 10)
    if (orientation >= 5 && orientation <= 8) {
      ;[w, h] = [h, w]
    }
    return { width: w, height: h }
  }
}
