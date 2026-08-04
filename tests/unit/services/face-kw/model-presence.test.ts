import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { getFaceModelPresence } from '../../../../desktop/src/main/services/face-kw/provider'

describe('getFaceModelPresence', () => {
  let directory: string
  let detectorPath: string
  let encoderPath: string

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-model-presence-'))
    detectorPath = path.join(directory, 'face_detector.onnx')
    encoderPath = path.join(directory, 'face_encoder.onnx')
    fs.writeFileSync(detectorPath, 'model-bytes')
  })

  afterEach(() => {
    fs.rmSync(directory, { recursive: true, force: true })
  })

  it('reports presence for absolute model paths without touching app settings', () => {
    const settings = {
      get: (key: string, fallback?: string) =>
        key === 'detector_model_path' ? detectorPath : key === 'encoder_model_path' ? encoderPath : (fallback ?? ''),
    }

    const presence = getFaceModelPresence(settings)

    expect(presence.detectorPath).toBe(detectorPath)
    expect(presence.encoderPath).toBe(encoderPath)
    expect(presence.detectorPresent).toBe(true)
    expect(presence.encoderPresent).toBe(false)
  })

  it('reads the configured setting keys', () => {
    const keys: string[] = []
    const settings = {
      get: (key: string, fallback?: string) => {
        keys.push(key)
        return fallback ?? ''
      },
    }

    getFaceModelPresence(settings)

    expect(keys).toContain('detector_model_path')
    expect(keys).toContain('encoder_model_path')
  })
})
