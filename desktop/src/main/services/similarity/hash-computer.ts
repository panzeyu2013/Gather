import sharp from 'sharp'
import { heavyTaskScheduler } from '../../utils/heavy-task-scheduler'

export async function computeDHash(imageBuffer: Buffer): Promise<string> {
  const { data } = await heavyTaskScheduler.run(
    () => sharp(imageBuffer)
      .resize(9, 8, { fit: 'fill' })
      .grayscale()
      .raw()
      .toBuffer({ resolveWithObject: true }),
    2,
  )

  const pixels = new Uint8Array(data)
  let hash = 0n

  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const left = pixels[y * 9 + x]
      const right = pixels[y * 9 + x + 1]
      if (left < right) {
        hash |= 1n << BigInt(y * 8 + x)
      }
    }
  }

  return hash.toString(16).padStart(16, '0')
}

export async function computeBatchDHash(imageBuffers: Buffer[], chunkSize = 8): Promise<Map<number, string>> {
  const results = new Map<number, string>()

  for (let i = 0; i < imageBuffers.length; i += chunkSize) {
    const chunk = imageBuffers.slice(i, i + chunkSize)
    const hashes = await Promise.all(chunk.map(async (buf, idx) => {
      const hash = await computeDHash(buf)
      return { index: i + idx, hash }
    }))
    for (const { index, hash } of hashes) {
      results.set(index, hash)
    }
  }

  return results
}
