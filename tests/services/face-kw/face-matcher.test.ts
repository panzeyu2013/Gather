import { describe, it, expect, vi } from 'vitest'

describe('FaceMatcher', () => {
  it('returns all unmatched when library is empty', async () => {
    const mockPersonRepo = {
      getAllEmbeddings: vi.fn().mockReturnValue([]),
    }
    const { FaceMatcher } = await import('../../../desktop/src/main/services/face-kw/face-matcher')
    const matcher = new FaceMatcher(mockPersonRepo as any)
    const embeddings = [new Float32Array([0.1, 0.2, 0.3])]
    const result = matcher.matchAgainstLibrary(embeddings, 0.5)
    expect(result.matched.size).toBe(0)
    expect(result.unmatched).toEqual([0])
  })

  it('finds matches above threshold', async () => {
    const embedding1 = new Float32Array([1.0, 0.0, 0.0, 0.0])
    const embedding2 = new Float32Array([0.99, 0.01, 0.0, 0.0])

    const mockPersonRepo = {
      getAllEmbeddings: vi.fn().mockReturnValue([
        { person_id: 'person-1', embedding: Buffer.from(embedding1.buffer) },
      ]),
    }
    const { FaceMatcher } = await import('../../../desktop/src/main/services/face-kw/face-matcher')
    const matcher = new FaceMatcher(mockPersonRepo as any)
    const result = matcher.matchAgainstLibrary([embedding2], 0.9)
    expect(result.matched.size).toBe(1)
    expect(result.matched.get(0)?.personId).toBe('person-1')
    expect(result.matched.get(0)?.confidence).toBeGreaterThan(0.98)
    expect(result.unmatched).toEqual([])
  })
})
