import { describe, expect, it } from 'vitest'
import {
  CosineHnswIndex,
  DEFAULT_HNSW_CONFIG,
} from '../../../../desktop/src/main/services/face-kw/hnsw-index'

// ---------------------------------------------------------------------------
// Deterministic synthetic corpus: 8 clusters of 512-dim normalized Gaussians
// (same generator as face-clusterer-lsh.test.ts), cluster centers spanning
// cosine thresholds 0.6-0.9. The quality gate measures recall of the exact
// brute-force top-1 at the production eps boundary, plus the stability of
// recall after incremental insertion (ROADMAP milestone V.1/V.2/V.3).
// ---------------------------------------------------------------------------

const DIM = 512
const CLUSTERS = 8
const ADJACENT_CENTER_COSINES = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9]
const SIGMA = 0.03
const SEED = 0x6a774c3

function mulberry32(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function makeGaussian(rand: () => number): () => number {
  return () => {
    let u = 0
    do { u = rand() } while (u === 0)
    const v = rand()
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
  }
}

function makeCenters(gauss: () => number): Float64Array[] {
  const centers: Float64Array[] = []
  const c1 = new Float64Array(DIM)
  c1[0] = 1
  centers.push(c1)
  for (let i = 1; i < CLUSTERS; i++) {
    const v = new Float64Array(DIM)
    let norm = 0
    for (let k = 0; k < DIM; k++) { v[k] = gauss(); norm += v[k] * v[k] }
    norm = Math.sqrt(norm)
    for (let k = 0; k < DIM; k++) v[k] /= norm
    for (const previous of centers) {
      let proj = 0
      for (let k = 0; k < DIM; k++) proj += v[k] * previous[k]
      for (let k = 0; k < DIM; k++) v[k] -= proj * previous[k]
    }
    norm = 0
    for (let k = 0; k < DIM; k++) norm += v[k] * v[k]
    norm = Math.sqrt(norm)
    for (let k = 0; k < DIM; k++) v[k] /= norm

    const target = ADJACENT_CENTER_COSINES[i - 1]
    const alpha = target / Math.sqrt(1 - target * target)
    const w = new Float64Array(DIM)
    let wnorm = 0
    for (let k = 0; k < DIM; k++) { w[k] = v[k] + alpha * centers[i - 1][k]; wnorm += w[k] * w[k] }
    wnorm = Math.sqrt(wnorm)
    for (let k = 0; k < DIM; k++) w[k] /= wnorm
    centers.push(w)
  }
  return centers
}

// All corpora (index rows and holdout queries) share ONE center set so the
// queries come from the same distribution as the indexed rows — that is the
// right gate for graph recall. Regenerating centers per seed would shift the
// query clusters away from the indexed ones and conflate distribution drift
// with graph quality.
const CENTERS = makeCenters(makeGaussian(mulberry32(SEED)))

function makeCorpus(count: number, seed = SEED): Float32Array[] {
  const rand = mulberry32(seed)
  const gauss = makeGaussian(rand)
  const rows: Float32Array[] = []
  for (let i = 0; i < count; i++) {
    const center = CENTERS[i % CLUSTERS]
    const row = new Float32Array(DIM)
    for (let k = 0; k < DIM; k++) {
      row[k] = center[k] + gauss() * SIGMA
    }
    // Normalize so the dot product is the cosine.
    let norm = 0
    for (let k = 0; k < DIM; k++) norm += row[k] * row[k]
    norm = Math.sqrt(norm)
    for (let k = 0; k < DIM; k++) row[k] /= norm
    rows.push(row)
  }
  return rows
}

function bruteTop1(query: Float32Array, rows: Float32Array[]): number {
  let best = -1
  let bestScore = -1
  for (let i = 0; i < rows.length; i++) {
    let dot = 0
    for (let k = 0; k < DIM; k++) dot += query[k] * rows[i][k]
    if (dot > bestScore) {
      bestScore = dot
      best = i
    }
  }
  return best
}

/**
 * Holdout-set recall: queries come from a DIFFERENT seed than the indexed
 * rows, so the exact brute-force top-1 is a real neighbor, not the query
 * row itself. Measuring self-recall would always pass (cos = 1.0) and would
 * never catch a degraded graph.
 */
function makeQueries(count: number): Float32Array[] {
  return makeCorpus(count, SEED ^ 0x13579bdf)
}

function measureRecall(
  queries: Float32Array[],
  rows: Float32Array[],
  index: CosineHnswIndex,
): { recallTop1: number; hits: number } {
  let hits = 0
  let total = 0
  for (const query of queries) {
    const exact = bruteTop1(query, rows)
    const topK = index.searchTopK(query, 0, 1)
    total++
    if (topK.count > 0 && topK.indices[0] === exact) hits++
  }
  return { recallTop1: total === 0 ? 0 : hits / total, hits }
}

describe('CosineHnswIndex quality gate (milestone V)', () => {
  it('recalls the exact brute-force top-1 neighbor (recall >= 0.9)', { timeout: 60_000 }, () => {
    const rows = makeCorpus(1_500)
    const index = new CosineHnswIndex({ dim: DIM })
    for (const row of rows) index.insert(row)

    const queries = makeQueries(375)
    const { recallTop1, hits } = measureRecall(queries, rows, index)
    expect(hits).toBeGreaterThanOrEqual(340)
    expect(recallTop1).toBeGreaterThanOrEqual(0.9)
  })

  it('returns hits above the threshold with exact-cosine scores', () => {
    const rows = makeCorpus(600)
    const index = new CosineHnswIndex({ dim: DIM })
    for (const row of rows) index.insert(row)

    // A query from the same cluster sits ~0.99 cosine from its neighbors;
    // the 0.7 threshold keeps the assertion meaningful (0.9 would admit only
    // the query itself, which is not even indexed here).
    const query = makeQueries(1)[0]
    const hits = index.searchByThreshold(query, 0, 0.7)
    expect(hits.count).toBeGreaterThan(0)
    let previous = Infinity
    for (let i = 0; i < hits.count; i++) {
      const score = hits.scores[i]
      expect(score).toBeGreaterThanOrEqual(0.7)
      // Scores must be returned in descending order.
      expect(score).toBeLessThanOrEqual(previous)
      previous = score
      // Spot-check one score against a direct cosine computation.
      const id = hits.indices[i]
      let dot = 0
      for (let k = 0; k < DIM; k++) dot += query[k] * rows[id][k]
      expect(Math.abs(score - dot)).toBeLessThan(1e-4)
    }
  })

  it('keeps recall stable after incremental insertion (no rebuild)', { timeout: 60_000 }, () => {
    const base = makeCorpus(1_200)
    const index = new CosineHnswIndex({ dim: DIM })
    for (const row of base) index.insert(row)
    const queries = makeQueries(300)
    const before = measureRecall(queries, base, index)

    // Insert a distinct (differently seeded) batch of rows without rebuilding.
    const additions = makeCorpus(400, SEED ^ 0x9e3779b9)
    for (const row of additions) index.insert(row)

    const after = measureRecall(queries, base, index)
    expect(index.size).toBe(base.length + additions.length)
    expect(after.recallTop1).toBeGreaterThanOrEqual(0.9)
    expect(after.recallTop1).toBeGreaterThanOrEqual(before.recallTop1 - 0.05)
  })

  it('grows capacity without losing entries or correctness', { timeout: 60_000 }, () => {
    // 1024 is the initial capacity; exceed it twice to force reallocation.
    const rows = makeCorpus(2_400)
    const index = new CosineHnswIndex({ dim: DIM })
    for (const row of rows) index.insert(row)
    expect(index.size).toBe(rows.length)

    const queries = makeQueries(375)
    const { recallTop1 } = measureRecall(queries, rows, index)
    expect(recallTop1).toBeGreaterThanOrEqual(0.9)
  })

  it('rejects dimension mismatches on insert and query', () => {
    const index = new CosineHnswIndex({ dim: DIM })
    expect(() => index.insert(new Float32Array(DIM - 1))).toThrow(/dimension mismatch/)
    index.insert(new Float32Array(DIM))
    // A too-short query would read out of bounds and poison the heap with
    // NaN; it must fail loudly instead (like the LSH index).
    expect(() => index.searchByThreshold(new Float32Array(DIM - 1), 0, 0.9))
      .toThrow(/shape mismatch/)
    expect(() => index.searchTopK(new Float32Array(DIM - 1), 0, 1))
      .toThrow(/shape mismatch/)
  })
})
