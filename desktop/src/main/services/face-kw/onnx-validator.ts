import { readFile, stat } from 'fs/promises'

interface Varint {
  value: number
  offset: number
}

function readVarint(buffer: Buffer, offset: number): Varint | null {
  let value = 0
  let shift = 0
  while (shift < 63) {
    if (offset >= buffer.length) return null
    const byte = buffer[offset++]
    value |= (byte & 0x7f) << shift
    if ((byte & 0x80) === 0) return { value, offset }
    shift += 7
  }
  return null
}

/**
 * Minimal protobuf walker for the top-level ONNX `ModelProto` message.
 *
 * Returns true only when every top-level field is well-formed, the message
 * ends cleanly at EOF, and the mandatory `graph` field (field 7) is present.
 * Zero-byte files, 1-byte garbage, and files truncated mid-field all fail,
 * so a partial or corrupt model is never mistaken for an installed one.
 */
export function isOnnxModelProto(buffer: Buffer): boolean {
  let offset = 0
  let hasGraph = false
  while (offset < buffer.length) {
    const tag = readVarint(buffer, offset)
    if (tag === null) return false
    offset = tag.offset
    const fieldNumber = tag.value >>> 3
    if (fieldNumber === 0) return false
    switch (tag.value & 0x07) {
      case 0: {
        const value = readVarint(buffer, offset)
        if (value === null) return false
        offset = value.offset
        break
      }
      case 1:
        if (offset + 8 > buffer.length) return false
        offset += 8
        break
      case 2: {
        const length = readVarint(buffer, offset)
        if (length === null) return false
        offset = length.offset
        if (offset + length.value > buffer.length) return false
        if (fieldNumber === 7) hasGraph = true
        offset += length.value
        break
      }
      case 5:
        if (offset + 4 > buffer.length) return false
        offset += 4
        break
      default:
        // Wire types 3/4 (protobuf groups) and 6/7 (reserved) are not emitted
        // by the ONNX serializer; treating them as invalid rejects corruption.
        return false
    }
  }
  return hasGraph
}

// The models are large (tens of MB). Cache validation results by file
// identity so repeated presence polls don't re-read the whole file.
const validationCache = new Map<string, { size: number; mtimeMs: number; valid: boolean }>()

/**
 * Returns true when the file exists, is non-empty, and parses as a structurally
 * valid ONNX ModelProto. Results are cached by (size, mtime) and invalidated as
 * soon as a re-download replaces the file.
 */
export async function isValidOnnxModel(filePath: string): Promise<boolean> {
  let info
  try {
    info = await stat(filePath)
  } catch {
    validationCache.delete(filePath)
    return false
  }
  if (info.size <= 0) {
    validationCache.delete(filePath)
    return false
  }
  const cached = validationCache.get(filePath)
  if (cached && cached.size === info.size && cached.mtimeMs === info.mtimeMs) {
    return cached.valid
  }
  try {
    const buffer = await readFile(filePath)
    const valid = isOnnxModelProto(buffer)
    if (validationCache.size >= 16) validationCache.clear()
    validationCache.set(filePath, { size: info.size, mtimeMs: info.mtimeMs, valid })
    return valid
  } catch {
    validationCache.delete(filePath)
    return false
  }
}
