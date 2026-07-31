import { describe, expect, it } from 'vitest'
import {
  validateFaceClusteringParameters,
} from '../../../desktop/src/main/services/face-kw/face-kw.service'

describe('face clustering parameter validation', () => {
  it.each([
    [Number.NaN, 2],
    [-0.1, 2],
    [1.1, 2],
    [0.6, 0],
    [0.6, 1.5],
  ])('rejects eps=%s minPts=%s', (eps, minPts) => {
    expect(() => validateFaceClusteringParameters(eps, minPts)).toThrow()
  })

  it('accepts supported similarity and minimum-sample values', () => {
    expect(() => validateFaceClusteringParameters(0.6, 1)).not.toThrow()
  })
})
