import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { getFaceModelPresence } from '../../../../desktop/src/main/services/face-kw/provider'
import { isOnnxModelProto } from '../../../../desktop/src/main/services/face-kw/onnx-validator'

// Minimal but structurally valid ModelProto: field 1 (ir_version, varint) and
// the mandatory field 7 (graph, length-delimited, empty).
function validOnnxModel(): Buffer {
  return Buffer.from([0x08, 0x01, 0x3a, 0x00])
}

describe('getFaceModelPresence', () => {
  let directory: string
  let detectorPath: string
  let encoderPath: string

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-model-presence-'))
    detectorPath = path.join(directory, 'face_detector.onnx')
    encoderPath = path.join(directory, 'face_encoder.onnx')
    fs.writeFileSync(detectorPath, validOnnxModel())
  })

  afterEach(() => {
    fs.rmSync(directory, { recursive: true, force: true })
  })

  it('reports presence for absolute model paths without touching app settings', async () => {
    const settings = {
      get: (key: string, fallback?: string) =>
        key === 'detector_model_path' ? detectorPath : key === 'encoder_model_path' ? encoderPath : (fallback ?? ''),
    }

    const presence = await getFaceModelPresence(settings)

    expect(presence.detectorPath).toBe(detectorPath)
    expect(presence.encoderPath).toBe(encoderPath)
    expect(presence.detectorPresent).toBe(true)
    expect(presence.encoderPresent).toBe(false)
  })

  it('reads the configured setting keys', async () => {
    const keys: string[] = []
    const settings = {
      get: (key: string, fallback?: string) => {
        keys.push(key)
        return fallback ?? ''
      },
    }

    await getFaceModelPresence(settings)

    expect(keys).toContain('detector_model_path')
    expect(keys).toContain('encoder_model_path')
  })

  it('does not report a zero-byte model as installed', async () => {
    fs.writeFileSync(detectorPath, '')
    const settings = {
      get: (key: string, fallback?: string) =>
        key === 'detector_model_path' ? detectorPath : key === 'encoder_model_path' ? encoderPath : (fallback ?? ''),
    }

    const presence = await getFaceModelPresence(settings)

    expect(presence.detectorPresent).toBe(false)
    expect(presence.encoderPresent).toBe(false)
  })

  it('does not report a 1-byte corrupt model as installed', async () => {
    fs.writeFileSync(detectorPath, Buffer.from([0xff]))
    const settings = {
      get: (key: string, fallback?: string) =>
        key === 'detector_model_path' ? detectorPath : key === 'encoder_model_path' ? encoderPath : (fallback ?? ''),
    }

    const presence = await getFaceModelPresence(settings)

    expect(isOnnxModelProto(Buffer.from([0xff]))).toBe(false)
    expect(presence.detectorPresent).toBe(false)
    expect(presence.encoderPresent).toBe(false)
  })
})
