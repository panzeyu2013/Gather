import { afterEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import {
  isOnnxModelProto,
  isValidOnnxModel,
} from '../../../../desktop/src/main/services/face-kw/onnx-validator'

// Field 1 (ir_version, varint) = 08 01
// Field 7 (graph, length-delimited, empty) = 3a 00
const VALID_MODEL = [0x08, 0x01, 0x3a, 0x00]

function bufferFrom(bytes: number[]): Buffer {
  return Buffer.from(bytes)
}

describe('isOnnxModelProto', () => {
  it('accepts a structurally valid minimal ModelProto', () => {
    expect(isOnnxModelProto(bufferFrom(VALID_MODEL))).toBe(true)
  })

  it('rejects an empty buffer', () => {
    expect(isOnnxModelProto(Buffer.alloc(0))).toBe(false)
  })

  it('rejects a 1-byte garbage file', () => {
    expect(isOnnxModelProto(Buffer.from([0xff]))).toBe(false)
    expect(isOnnxModelProto(Buffer.from([0x08]))).toBe(false)
  })

  it('rejects random non-ONNX bytes', () => {
    expect(isOnnxModelProto(Buffer.from('model-bytes'))).toBe(false)
  })

  it('rejects a file truncated inside the graph payload', () => {
    // ir_version(1) + graph tag + declared length 16, but only 4 bytes follow.
    expect(isOnnxModelProto(bufferFrom([0x08, 0x01, 0x3a, 0x10, 0, 0, 0, 0]))).toBe(false)
  })

  it('rejects a valid prefix that is missing the mandatory graph field', () => {
    // Only ir_version and producer_name: no field 7.
    expect(isOnnxModelProto(bufferFrom([0x08, 0x01, 0x12, 0x02, 0x61, 0x62]))).toBe(false)
  })

  it('rejects an unknown protobuf wire type', () => {
    // field 1, wire type 3 (start group) = 0x0b
    expect(isOnnxModelProto(bufferFrom([0x0b, 0x00, 0x00]))).toBe(false)
  })
})

describe('isValidOnnxModel', () => {
  const tempDirs: string[] = []

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })

  it('returns false for missing files', async () => {
    expect(await isValidOnnxModel(path.join(os.tmpdir(), 'does-not-exist.onnx'))).toBe(false)
  })

  it('returns true for a valid file and false for a truncated one', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-onnx-'))
    tempDirs.push(dir)
    const validPath = path.join(dir, 'valid.onnx')
    const truncatedPath = path.join(dir, 'truncated.onnx')
    fs.writeFileSync(validPath, bufferFrom(VALID_MODEL))
    // ir_version + graph tag declaring 100 bytes with no payload.
    fs.writeFileSync(truncatedPath, bufferFrom([0x08, 0x01, 0x3a, 0x64]))

    expect(await isValidOnnxModel(validPath)).toBe(true)
    expect(await isValidOnnxModel(truncatedPath)).toBe(false)
  })
})
