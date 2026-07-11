import { execFile } from 'child_process'
import { promisify } from 'util'
import * as fs from 'fs'
import * as path from 'path'
import * as os from 'os'
import sharp from 'sharp'
import { SettingsService } from '../../settings'
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
  private settings = SettingsService.getInstance()

  private static RAW_EXTENSIONS = new Set([
    '.cr2', '.cr3', '.nef', '.nrw', '.arw',
    '.raf', '.dng', '.orf', '.rw2', '.pef',
    '.srw', '.srf', '.x3f', '.3fr', '.fff',
    '.mef', '.mos', '.iiq', '.eip',
  ])

  supports(ext: string): boolean {
    return SipsDecoder.RAW_EXTENSIONS.has(ext)
  }

  async getPreview(path: string, maxDimension = 1920): Promise<DecodeResult> {
    const buffer = await sipsToBuffer([
      '-Z', String(maxDimension),
      '-s', 'format', 'jpeg',
      path,
    ])
    const metadata = await sharp(buffer).metadata()
    return {
      buffer,
      format: 'jpeg',
      width: metadata.width ?? maxDimension,
      height: metadata.height ?? maxDimension,
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
      '-g', 'pixelWidth', '-g', 'pixelHeight', path,
    ])
    return {
      width: parseInt(stdout.match(/pixelWidth: (\d+)/)?.[1] ?? '0', 10),
      height: parseInt(stdout.match(/pixelHeight: (\d+)/)?.[1] ?? '0', 10),
    }
  }
}
