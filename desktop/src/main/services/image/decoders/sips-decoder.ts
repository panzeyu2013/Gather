import { execFile } from 'child_process'
import { promisify } from 'util'
import * as fsp from 'fs/promises'
import * as path from 'path'
import * as os from 'os'
import sharp from 'sharp'
import { IMAGE_CONFIG } from '../image-config'
import type { ImageDecoder, DecodeResult } from '../decoder'

const execFileAsync = promisify(execFile)

// A corrupt or unusually large RAW can make sips hang. Without a timeout the
// decode slot is occupied forever, stalling every other thumbnail/preview.
const SIPS_RENDER_TIMEOUT_MS = 120_000
const SIPS_DIMENSIONS_TIMEOUT_MS = 30_000

function tempJpegPath(): string {
  return path.join(os.tmpdir(), `gather-sips-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`)
}

async function sipsToBuffer(args: string[]): Promise<Buffer> {
  const outPath = tempJpegPath()
  try {
    await execFileAsync('sips', [...args, '--out', outPath], { timeout: SIPS_RENDER_TIMEOUT_MS })
    return await fsp.readFile(outPath)
  } finally {
    try { await fsp.unlink(outPath) } catch {}
  }
}

export class SipsDecoder implements ImageDecoder {
  readonly name = 'Sips (Apple RAW)'

  private static RAW_EXTENSIONS = new Set(IMAGE_CONFIG.sips.rawExtensions)

  supports(ext: string): boolean {
    return SipsDecoder.RAW_EXTENSIONS.has(ext)
  }

  async getPreview(path: string, _maxDimension?: number): Promise<DecodeResult> {
    const args = _maxDimension
      ? ['-Z', String(_maxDimension), '-s', 'format', 'jpeg', path]
      : ['-s', 'format', 'jpeg', path]
    const buffer = await sipsToBuffer(args)
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
    ], { timeout: SIPS_DIMENSIONS_TIMEOUT_MS })
    let w = parseInt(stdout.match(/pixelWidth: (\d+)/)?.[1] ?? '0', 10)
    let h = parseInt(stdout.match(/pixelHeight: (\d+)/)?.[1] ?? '0', 10)
    const orientation = parseInt(stdout.match(/orientation: (\d+)/)?.[1] ?? '1', 10)
    if (orientation >= 5 && orientation <= 8) {
      ;[w, h] = [h, w]
    }
    if (w <= 0 || h <= 0) {
      throw new Error(`Unable to determine image dimensions: ${path}`)
    }
    return { width: w, height: h }
  }
}
