import { describe, it, expect } from 'vitest'
import { clusterEmbeddings } from '../../../../desktop/src/main/services/face-kw/face-clusterer'

describe('clusterEmbeddings', () => {
  it('clusters identical embeddings', () => {
    const embedding = Array(128).fill(0.1)
    const norm = Math.sqrt(embedding.reduce((s, v) => s + v * v, 0))
    const normalized = embedding.map(v => v / norm)

    const entries = [
      { observationId: 1, embedding: normalized, photoId: 'a' },
      { observationId: 2, embedding: normalized, photoId: 'b' },
      { observationId: 3, embedding: normalized, photoId: 'c' },
    ]
    const result = clusterEmbeddings(entries, 0.9, 2)
    expect(result.clusters).toHaveLength(1)
    expect(result.clusters[0]).toHaveLength(3)
    expect(result.noise).toHaveLength(0)
  })

  it('separates orthogonal embeddings', () => {
    const embA = Array(128).fill(0)
    embA[0] = 1
    const embB = Array(128).fill(0)
    embB[1] = 1

    const entries = [
      { observationId: 1, embedding: embA, photoId: 'a' },
      { observationId: 2, embedding: embB, photoId: 'b' },
    ]
    const result = clusterEmbeddings(entries, 0.9, 2)
    expect(result.clusters).toHaveLength(0)
    expect(result.noise).toHaveLength(2)
  })

  it('handles empty input', () => {
    const result = clusterEmbeddings([], 0.5, 2)
    expect(result.clusters).toHaveLength(0)
    expect(result.noise).toHaveLength(0)
  })

  it('accepts Float32Array embeddings', () => {
    const embedding = new Float32Array(128).fill(0.1)
    const norm = Math.sqrt(embedding.reduce((s, v) => s + v * v, 0))
    const normalized = embedding.map(v => v / norm)

    const entries = [
      { observationId: 1, embedding: normalized, photoId: 'a' },
      { observationId: 2, embedding: normalized, photoId: 'b' },
    ]
    const result = clusterEmbeddings(entries, 0.9, 2)
    expect(result.clusters).toHaveLength(1)
    expect(result.clusters[0]).toHaveLength(2)
    expect(result.clusters[0][0].observationId).toBe(1)
  })

  it('reports progress monotonically up to the total', () => {
    const embedding = Array(128).fill(0.1)
    const norm = Math.sqrt(embedding.reduce((s, v) => s + v * v, 0))
    const normalized = embedding.map(v => v / norm)
    const entries = Array.from({ length: 40 }, (_, index) => ({
      observationId: index + 1,
      embedding: normalized,
      photoId: `p${index}`,
    }))

    const progress: Array<[number, number]> = []
    clusterEmbeddings(entries, 0.9, 2, (current, total) => {
      progress.push([current, total])
    })

    expect(progress.length).toBeGreaterThan(0)
    for (const [current, total] of progress) {
      expect(total).toBe(entries.length)
      expect(current).toBeGreaterThanOrEqual(0)
      expect(current).toBeLessThanOrEqual(total)
    }
    expect(progress[progress.length - 1][0]).toBe(entries.length)
  })

  it('keeps the heartbeat alive while expanding a giant cluster (exact path)', () => {
    // A single cluster of 2000 identical points means the outer scan stops at
    // i = 0 while the BFS expansion processes everything. Without the BFS
    // heartbeat the callback would fire only every n/20 rows of the outer
    // scan (~21 times); with it, the expansion emits far more frames, so the
    // caller's no-progress timeout cannot kill an active worker.
    const embedding = Array(128).fill(0.1)
    const norm = Math.sqrt(embedding.reduce((s, v) => s + v * v, 0))
    const normalized = embedding.map(v => v / norm)
    const entries = Array.from({ length: 2000 }, (_, index) => ({
      observationId: index + 1,
      embedding: normalized,
      photoId: `p${index}`,
    }))

    const progress: Array<[number, number]> = []
    clusterEmbeddings(entries, 0.9, 2, (current, total) => {
      progress.push([current, total])
    }, { enabled: false })

    expect(progress.length).toBeGreaterThanOrEqual(30)
    let last = -1
    for (const [current] of progress) {
      expect(current).toBeGreaterThanOrEqual(last)
      last = current
    }
    expect(progress[progress.length - 1][0]).toBe(entries.length)
  })

  it('throws on mixed embedding dimensions', () => {
    const entries = [
      { observationId: 1, embedding: Array(128).fill(0.1), photoId: 'a' },
      { observationId: 2, embedding: Array(64).fill(0.1), photoId: 'b' },
    ]
    expect(() => clusterEmbeddings(entries, 0.9, 2)).toThrow(/dimension mismatch/)
  })
})
