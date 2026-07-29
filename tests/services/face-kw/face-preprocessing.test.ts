import { describe, expect, it } from 'vitest'
import { resolveScrfdLayout } from '../../../desktop/src/main/services/face-kw/face-detector'
import { estimateSimilarityTransform } from '../../../desktop/src/main/services/face-kw/face-encoder'
import type { FaceLandmarks } from '../../../desktop/src/main/services/face-kw/face-detector'
import { MODEL_CONFIG } from '../../../desktop/src/main/services/face-kw/model-config'

describe('InsightFace preprocessing contracts', () => {
  it('uses the recommended gallery detection and recognition resolutions', () => {
    expect(MODEL_CONFIG.detect.inputSize).toBe(640)
    expect(MODEL_CONFIG.detect.secondaryInputSize).toBe(128)
    expect(MODEL_CONFIG.encode.inputSize).toBe(112)
  })

  it('recognizes the official SCRFD output layouts', () => {
    expect(resolveScrfdLayout(9)).toEqual({
      featureMaps: 3,
      strides: [8, 16, 32],
      anchorsPerCell: 2,
      hasLandmarks: true,
    })
    expect(resolveScrfdLayout(15)).toEqual({
      featureMaps: 5,
      strides: [8, 16, 32, 64, 128],
      anchorsPerCell: 1,
      hasLandmarks: true,
    })
    expect(() => resolveScrfdLayout(1)).toThrow('Unsupported SCRFD')
  })

  it('estimates a similarity transform that maps all landmarks', () => {
    const source: FaceLandmarks = [
      [10, 20], [30, 20], [20, 30], [12, 40], [28, 40],
    ]
    const destination = source.map(([x, y]) => [
      x * 1.5 - y * 0.25 + 8,
      x * 0.25 + y * 1.5 - 3,
    ]) as FaceLandmarks
    const transform = estimateSimilarityTransform(source, destination)

    for (let index = 0; index < source.length; index++) {
      const [x, y] = source[index]
      expect(transform.a * x - transform.b * y + transform.tx)
        .toBeCloseTo(destination[index][0], 6)
      expect(transform.b * x + transform.a * y + transform.ty)
        .toBeCloseTo(destination[index][1], 6)
    }
  })
})
