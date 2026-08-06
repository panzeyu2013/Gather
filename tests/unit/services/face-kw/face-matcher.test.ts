import { describe, it, expect, vi } from 'vitest'

describe('FaceMatcher', () => {
  it('returns all unmatched when library is empty', async () => {
    const mockPersonRepo = {
      getAllEmbeddings: vi.fn().mockReturnValue([]),
    }
    const { FaceMatcher } = await import('../../../../desktop/src/main/services/face-kw/face-matcher')
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
    const { FaceMatcher } = await import('../../../../desktop/src/main/services/face-kw/face-matcher')
    const matcher = new FaceMatcher(mockPersonRepo as any)
    const result = matcher.matchAgainstLibrary([embedding2], 0.9)
    expect(result.matched.size).toBe(1)
    expect(result.matched.get(0)?.personId).toBe('person-1')
    expect(result.matched.get(0)?.confidence).toBeGreaterThan(0.98)
    expect(result.unmatched).toEqual([])
  })
})

describe('FaceMatcher ANN path (angular LSH)', () => {
  async function buildMatcher(embeddings: Float32Array[], personIds: string[]) {
    const { FaceMatcher } = await import('../../../../desktop/src/main/services/face-kw/face-matcher')
    const mockPersonRepo = {
      getAllEmbeddings: vi.fn().mockReturnValue(
        embeddings.map((e, i) => ({ person_id: personIds[i], embedding: Buffer.from(e.buffer) })),
      ),
    }
    // Force the LSH branch regardless of library size.
    return new FaceMatcher(mockPersonRepo as any, 1)
  }

  it('matches the same persons as the exact scan', async () => {
    // Unit vectors in R^4: 4 well-separated library persons.
    const library = [
      new Float32Array([1, 0, 0, 0]),
      new Float32Array([0, 1, 0, 0]),
      new Float32Array([0, 0, 1, 0]),
      new Float32Array([0, 0, 0, 1]),
    ]
    const queries = [
      new Float32Array([0.99, 0.02, 0, 0]),  // -> person 1
      new Float32Array([0.01, 0.98, 0.01, 0]), // -> person 2
      new Float32Array([0.05, 0.02, 0.9, 0.1]), // -> person 3
      new Float32Array([0.3, 0.3, 0.3, 0.3]),  // below threshold -> unmatched
    ]
    const matcher = await buildMatcher(library, ['p1', 'p2', 'p3', 'p4'])
    const result = matcher.matchAgainstLibrary(queries, 0.85)
    expect(result.matched.get(0)?.personId).toBe('p1')
    expect(result.matched.get(1)?.personId).toBe('p2')
    expect(result.matched.get(2)?.personId).toBe('p3')
    expect(result.matched.get(3)).toBeUndefined()
    expect(result.unmatched).toEqual([3])
  })

  it('uses exact cosine semantics (non-unit queries still score correctly)', async () => {
    const library = [new Float32Array([1, 0, 0, 0])]
    const query = new Float32Array([5, 0, 0, 0]) // same direction, magnitude 5
    const matcher = await buildMatcher(library, ['p1'])
    const result = matcher.matchAgainstLibrary([query], 0.99)
    expect(result.matched.get(0)?.personId).toBe('p1')
    expect(result.matched.get(0)?.confidence).toBeCloseTo(1, 6)
  })
})
