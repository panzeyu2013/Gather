import sharp from 'sharp'

export async function computeDHash(imagePath: string): Promise<string> {
  const { data } = await sharp(imagePath)
    .resize(9, 8, { fit: 'fill' })
    .grayscale()
    .raw()
    .toBuffer({ resolveWithObject: true })

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

export async function computeBatchDHash(imagePaths: string[]): Promise<Map<string, string>> {
  const results = new Map<string, string>()
  const CHUNK_SIZE = 8

  for (let i = 0; i < imagePaths.length; i += CHUNK_SIZE) {
    const chunk = imagePaths.slice(i, i + CHUNK_SIZE)
    const hashes = await Promise.all(chunk.map(async (p) => ({ path: p, hash: await computeDHash(p) })))
    for (const { path, hash } of hashes) {
      results.set(path, hash)
    }
  }

  return results
}

export function hammingDistance(hash1: string, hash2: string): number {
  const a = BigInt(`0x${hash1}`)
  const b = BigInt(`0x${hash2}`)
  let xor = a ^ b
  let count = 0
  while (xor > 0n) {
    count++
    xor &= xor - 1n
  }
  return count
}
