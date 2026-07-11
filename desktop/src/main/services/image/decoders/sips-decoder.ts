import { execFile } from 'child_process'
import { promisify } from 'util'
import sharp from 'sharp'
import { SettingsService } from '../../settings'
import type { ImageDecoder, DecodeResult } from '../decoder'

const execFileAsync = promisify(execFile)

// Helper for binary output (image data): encoding=buffer + increased maxBuffer for large previews
function execFileBuffer(cmd: string, args: string[]): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { encoding: 'buffer', maxBuffer: 50 * 1024 * 1024 }, (err, stdout) => {
      if (err) return reject(err)
      resolve(stdout)
    })
  })
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
    const stdout = await execFileBuffer('sips', [
      '-Z', String(maxDimension),
      '-s', 'format', 'jpeg',
      path,
      '--stdout',
    ])
    const metadata = await sharp(stdout).metadata()
    return {
      buffer: stdout,
      format: 'jpeg',
      width: metadata.width ?? maxDimension,
      height: metadata.height ?? maxDimension,
    }
  }

  async getThumbnail(path: string, size: number): Promise<DecodeResult> {
    const stdout = await execFileBuffer('sips', [
      '-Z', String(size),
      '-s', 'format', 'jpeg',
      path,
      '--stdout',
    ])
    const metadata = await sharp(stdout).metadata()
    return {
      buffer: stdout,
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
