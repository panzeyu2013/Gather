import { describe, it, expect } from 'vitest'
import { hammingDistance } from '../../../desktop/src/main/services/similarity/hash-computer'

describe('hammingDistance', () => {
  it('returns 0 for identical hashes', () => {
    expect(hammingDistance('ffffffffffffffff', 'ffffffffffffffff')).toBe(0)
  })

  it('returns 64 for complementary hashes', () => {
    expect(hammingDistance('ffffffffffffffff', '0000000000000000')).toBe(64)
  })

  it('returns correct distance for known values', () => {
    expect(hammingDistance('ffffffffffffffff', 'f0f0f0f0f0f0f0f0')).toBe(32)
  })

  it('handles different length hashes', () => {
    expect(hammingDistance('ff', '00')).toBe(8)
    expect(hammingDistance('ffff', '0000')).toBe(16)
  })
})
