import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import sharp from 'sharp'

export interface ReliabilityFixture {
  root: string
  cleanup: () => Promise<void>
  photoPath(name?: string): string
  xmpPath(name?: string): string
  createJpeg(name?: string): Promise<string>
  createSharedRawJpegPair(baseName?: string): Promise<{ rawPath: string; jpegPath: string; xmpPath: string }>
  createInvalidFile(name?: string): Promise<string>
}

export async function createReliabilityFixture(prefix = 'gather-reliability-'): Promise<ReliabilityFixture> {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), prefix))

  const photoPath = (name = 'IMG_0001.jpg') => path.join(root, name)
  const xmpPath = (name = 'IMG_0001.xmp') => path.join(root, name)

  const createJpeg = async (name = 'IMG_0001.jpg') => {
    const output = photoPath(name)
    await sharp({
      create: {
        width: 32,
        height: 24,
        channels: 3,
        background: { r: 80, g: 120, b: 180 },
      },
    }).jpeg().toFile(output)
    return output
  }

  const createSharedRawJpegPair = async (baseName = 'IMG_0001') => {
    const jpegPath = await createJpeg(`${baseName}.JPG`)
    const rawPath = photoPath(`${baseName}.NEF`)
    // The RAW bytes are intentionally only a path/sidecar fixture. Tests that need
    // real RAW decoding must provide GATHER_TEST_RAW_FIXTURE explicitly.
    await fs.writeFile(rawPath, Buffer.from('synthetic-raw-fixture'))
    return { rawPath, jpegPath, xmpPath: xmpPath(`${baseName}.xmp`) }
  }

  const createInvalidFile = async (name = 'broken.jpg') => {
    const output = photoPath(name)
    await fs.writeFile(output, Buffer.from('not-a-valid-image'))
    return output
  }

  return {
    root,
    cleanup: () => fs.rm(root, { recursive: true, force: true }),
    photoPath,
    xmpPath,
    createJpeg,
    createSharedRawJpegPair,
    createInvalidFile,
  }
}

