export interface DimensionResult {
  width: number
  height: number
}

export function readDimensions(buf: Buffer, ext: string): DimensionResult | null {
  if (buf.length < 12) return null

  const format = detectFormat(buf, ext)
  switch (format) {
    case 'jpeg': return readJpeg(buf)
    case 'png': return readPng(buf)
    case 'gif': return readGif(buf)
    case 'bmp': return readBmp(buf)
    case 'webp': return readWebp(buf)
    case 'tiff': return readTiff(buf)
    default: return null
  }
}

type Format = 'jpeg' | 'png' | 'gif' | 'bmp' | 'webp' | 'tiff' | null

function detectFormat(buf: Buffer, ext: string): Format {
  if (buf[0] === 0xFF && buf[1] === 0xD8) return 'jpeg'
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47) return 'png'
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) return 'gif'
  if (buf[0] === 0x42 && buf[1] === 0x4D) return 'bmp'
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46) {
    if (buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return 'webp'
  }
  if ((buf[0] === 0x49 && buf[1] === 0x49 && buf[2] === 0x2A && buf[3] === 0x00) ||
      (buf[0] === 0x4D && buf[1] === 0x4D && buf[2] === 0x00 && buf[3] === 0x2A)) return 'tiff'
  if (ext === '.tif' || ext === '.tiff') return 'tiff'
  return null
}

function readJpeg(buf: Buffer): DimensionResult | null {
  for (let i = 0; i < buf.length - 5; i++) {
    if (buf[i] !== 0xFF) continue
    const marker = buf[i + 1]
    if (marker !== 0xC0 && marker !== 0xC1 && marker !== 0xC2) continue
    const length = buf.readUInt16BE(i + 2)
    if (length < 7 || i + 2 + length > buf.length) continue
    const h = buf.readUInt16BE(i + 5)
    const w = buf.readUInt16BE(i + 7)
    if (w > 0 && h > 0) return { width: w, height: h }
    i += 2 + length - 1
  }
  return null
}

function readPng(buf: Buffer): DimensionResult | null {
  if (buf.length < 24) return null
  if (buf[12] !== 0x49 || buf[13] !== 0x48 || buf[14] !== 0x44 || buf[15] !== 0x52) return null
  const w = buf.readUInt32BE(16)
  const h = buf.readUInt32BE(20)
  if (w > 0 && h > 0) return { width: w, height: h }
  return null
}

function readGif(buf: Buffer): DimensionResult | null {
  if (buf.length < 10) return null
  const w = buf.readUInt16LE(6)
  const h = buf.readUInt16LE(8)
  if (w > 0 && h > 0) return { width: w, height: h }
  return null
}

function readBmp(buf: Buffer): DimensionResult | null {
  if (buf.length < 26) return null
  const w = buf.readInt32LE(18)
  const h = Math.abs(buf.readInt32LE(22))
  if (w > 0 && h > 0) return { width: w, height: h }
  return null
}

function readWebp(buf: Buffer): DimensionResult | null {
  if (buf.length < 30) return null
  const chunkType = buf.toString('ascii', 12, 16)
  if (chunkType === 'VP8 ') {
    const w = buf.readUInt16LE(26) & 0x3FFF
    const h = buf.readUInt16LE(28) & 0x3FFF
    if (w > 0 && h > 0) return { width: w, height: h }
  } else if (chunkType === 'VP8L') {
    const bits = buf.readUInt32LE(21)
    const w = (bits & 0x3FFF) + 1
    const h = ((bits >> 14) & 0x3FFF) + 1
    if (w > 0 && h > 0) return { width: w, height: h }
  } else if (chunkType === 'VP8X') {
    if (buf.length < 24) return null
    const w = (buf.readUIntLE(18, 3) & 0xFFFFFF) + 1
    const h = (buf.readUIntLE(21, 3) & 0xFFFFFF) + 1
    if (w > 0 && h > 0) return { width: w, height: h }
  }
  return null
}

function readTiff(buf: Buffer): DimensionResult | null {
  if (buf.length < 8) return null
  const isLE = buf[0] === 0x49
  const r16 = (o: number) => isLE ? buf.readUInt16LE(o) : buf.readUInt16BE(o)
  const r32 = (o: number) => isLE ? buf.readUInt32LE(o) : buf.readUInt32BE(o)

  let offset = r32(4)
  for (let ifd = 0; ifd < 4 && offset + 2 <= buf.length; ifd++) {
    const n = r16(offset)
    let w = 0, h = 0
    for (let i = 0; i < n && offset + 2 + (i + 1) * 12 <= buf.length; i++) {
      const eo = offset + 2 + i * 12
      const tag = r16(eo)
      const type = r16(eo + 2)
      const valOffset = eo + 8
      if (tag === 0x0100) w = type === 3 ? r16(valOffset) : r32(valOffset)
      if (tag === 0x0101) h = type === 3 ? r16(valOffset) : r32(valOffset)
    }
    if (w > 0 && h > 0) return { width: w, height: h }
    if (offset + 2 + n * 12 + 4 > buf.length) break
    offset = r32(offset + 2 + n * 12)
  }
  return null
}
