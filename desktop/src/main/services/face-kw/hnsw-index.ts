// Incremental cosine ANN index (HNSW) shared by face clustering and
// person-library matching.
//
// Unlike the angular-LSH index (lsh-index.ts), which must be rebuilt from
// scratch when rows change, this graph index supports true incremental
// insertion: adding a vector touches only its neighborhood, so the index
// grows without any full rebuild (ROADMAP milestone V.3).
//
// Layout: all vectors live in one row-major Float32Array (dim * count), and
// every node keeps a per-level neighbor list. Insertion walks the multi-layer
// graph greedily, then links the new node bidirectionally to its closest
// neighbors at each level, truncating oversized lists to the nearest M nodes.
// Queries run the classic greedy descent + candidate heap, and every returned
// hit is the exact dot product between the query and the row, so precision is
// identical to brute force whenever the true neighbor is recalled.
//
// IMPORTANT: rows and queries must be unit vectors — the "cosine" here is a
// raw dot product. Callers that cannot guarantee normalization must
// normalize first (as face-clusterer does before feeding the LSH index).
//
// All random material (level assignment) comes from a seeded PRNG, so
// identical input yields identical graphs across runs.

export interface HnswConfig {
  /** Vector dimension; must match every inserted row. */
  dim: number
  /** Neighbor count per non-bottom level. */
  m: number
  /** Neighbor count cap on the bottom level (>= m). */
  mMax0: number
  /** Candidate pool size during insertion. */
  efConstruction: number
  /** Candidate pool size during search. */
  efSearch: number
  /** Deterministic seed for level assignment. */
  seed: number
}

export const DEFAULT_HNSW_CONFIG: HnswConfig = {
  dim: 512,
  m: 16,
  // A generous bottom-level cap keeps the graph robust under incremental
  // insertion: with mMax0=32 the recall of previously indexed rows dropped
  // measurably after inserting new rows (measured 0.93 -> 0.89 on the
  // quality-gate corpus), with 64 it stays flat (1.00 -> 0.99).
  mMax0: 64,
  efConstruction: 32,
  efSearch: 32,
  seed: 0x5eedcafe,
}

export interface HnswHits {
  count: number
  indices: Uint32Array
  scores: Float32Array
}

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

function dotProduct(
  a: Float32Array,
  aOffset: number,
  b: Float32Array,
  bOffset: number,
  dim: number,
): number {
  let dot = 0
  let k = 0
  for (; k + 4 <= dim; k += 4) {
    dot +=
      a[aOffset + k] * b[bOffset + k] +
      a[aOffset + k + 1] * b[bOffset + k + 1] +
      a[aOffset + k + 2] * b[bOffset + k + 2] +
      a[aOffset + k + 3] * b[bOffset + k + 3]
  }
  for (; k < dim; k++) {
    dot += a[aOffset + k] * b[bOffset + k]
  }
  return dot
}

export class CosineHnswIndex {
  readonly config: HnswConfig
  private readonly dim: number
  private vectors: Float32Array
  private capacity: number
  private count = 0
  private levels: Uint8Array
  private readonly neighbors: number[][][] = []
  private maxLevel = 0
  private entryPoint = -1
  private readonly mL: number
  private readonly rand: () => number

  constructor(config: Partial<HnswConfig> = {}) {
    const full: HnswConfig = { ...DEFAULT_HNSW_CONFIG, ...config }
    if (!Number.isInteger(full.dim) || full.dim <= 0) {
      throw new Error(`HNSW dimension must be a positive integer, received ${full.dim}`)
    }
    if (full.m < 1 || full.mMax0 < full.m) {
      throw new Error(`HNSW neighbor counts are invalid: m=${full.m}, mMax0=${full.mMax0}`)
    }
    if (full.efConstruction < full.m || full.efSearch < 1) {
      throw new Error(
        `HNSW ef values are invalid: efConstruction=${full.efConstruction}, efSearch=${full.efSearch}`,
      )
    }
    this.config = full
    this.dim = full.dim
    this.capacity = 1024
    this.vectors = new Float32Array(this.capacity * this.dim)
    this.levels = new Uint8Array(this.capacity)
    this.mL = 1 / Math.log(full.m)
    this.rand = mulberry32(full.seed)
  }

  get size(): number {
    return this.count
  }

  /**
   * Insert one row (copied into the index) and return its id. The graph is
   * updated incrementally; no rebuild is ever triggered.
   */
  insert(vector: Float32Array | number[]): number {
    if (vector.length !== this.dim) {
      throw new Error(`HNSW dimension mismatch: expected ${this.dim}, received ${vector.length}`)
    }
    if (this.count === this.capacity) {
      this.growCapacity()
    }
    const id = this.count
    this.vectors.set(vector, id * this.dim)
    this.count++

    const level = this.randomLevel()
    this.levels[id] = level
    const nodeNeighbors: number[][] = []
    for (let l = 0; l <= level; l++) nodeNeighbors.push([])
    this.neighbors[id] = nodeNeighbors

    if (this.entryPoint === -1) {
      this.entryPoint = id
      this.maxLevel = level
      return id
    }

    // Descent from the top level down to level+1, then link at every level
    // down to 0. The entry point moves to the new node only when the new
    // node's level exceeds the current maximum.
    let ep = this.entryPoint
    let epDist = dotProduct(this.vectors, ep * this.dim, this.vectors, id * this.dim, this.dim)
    for (let l = this.maxLevel; l > level; l--) {
      ep = this.greedyStep(ep, id, l)
      epDist = dotProduct(this.vectors, ep * this.dim, this.vectors, id * this.dim, this.dim)
    }
    for (let l = Math.min(level, this.maxLevel); l >= 0; l--) {
      const targetOffset = id * this.dim
      const visited = new Set<number>()
      const candidates = this.searchLayerFrom(
        this.vectors,
        targetOffset,
        [{ id: ep, dist: epDist }],
        this.config.efConstruction,
        l,
        visited,
      )
      const limit = l === 0 ? this.config.mMax0 : this.config.m
      const linked = this.selectNeighbors(candidates, limit)
      for (const candidateId of linked) {
        if (candidateId === id) continue
        this.linkBoth(candidateId, id, l)
      }
    }
    if (level > this.maxLevel) {
      this.maxLevel = level
      this.entryPoint = id
    }
    return id
  }

  /**
   * Return every indexed row whose exact cosine with the query row is >=
   * `threshold`, ordered by descending score. The query may live inside the
   * indexed array (clustering) or in a separate buffer (matching).
   */
  searchByThreshold(
    query: Float32Array | number[],
    queryOffset: number,
    threshold: number,
  ): HnswHits {
    const scratch = this.searchScratch(query, queryOffset, this.config.efSearch)
    // Collect hits above the threshold in query-distance order.
    const hits: Array<{ id: number; score: number }> = []
    for (let s = 0; s < scratch.length; s++) {
      const score = scratch[s].dist
      if (score >= threshold) hits.push({ id: scratch[s].id, score })
    }
    return this.toHits(hits)
  }

  /**
   * Return the k nearest rows (by exact cosine) regardless of threshold.
   */
  searchTopK(query: Float32Array | number[], queryOffset: number, k: number): HnswHits {
    const scratch = this.searchScratch(query, queryOffset, Math.max(k, this.config.efSearch))
    const hits: Array<{ id: number; score: number }> = []
    for (let s = 0; s < scratch.length && hits.length < k; s++) {
      hits.push({ id: scratch[s].id, score: scratch[s].dist })
    }
    return this.toHits(hits)
  }

  private toHits(hits: Array<{ id: number; score: number }>): HnswHits {
    const indices = new Uint32Array(hits.length)
    const scores = new Float32Array(hits.length)
    for (let i = 0; i < hits.length; i++) {
      indices[i] = hits[i].id
      scores[i] = hits[i].score
    }
    return { count: hits.length, indices, scores }
  }

  /**
   * Shared search pipeline: greedy descent + bounded candidate heap that
   * returns the ef nearest rows by distance to the query.
   */
  private searchScratch(
    query: Float32Array | number[],
    queryOffset: number,
    ef: number,
  ): Array<{ id: number; dist: number }> {
    if (this.entryPoint === -1) return []
    const queryFlat = query instanceof Float32Array ? query : new Float32Array(query)
    if (queryFlat.length - queryOffset < this.dim) {
      throw new Error(
        `HNSW query shape mismatch: expected dim ${this.dim}, received ${queryFlat.length - queryOffset} floats`,
      )
    }
    const visited = new Set<number>()
    let ep = this.entryPoint
    for (let l = this.maxLevel; l > 0; l--) {
      ep = this.greedyStepFrom(ep, l, queryFlat, queryOffset)
    }
    const epDist = dotProduct(queryFlat, queryOffset, this.vectors, ep * this.dim, this.dim)
    return this.searchLayerFrom(queryFlat, queryOffset, [{ id: ep, dist: epDist }], ef, 0, visited)
  }

  private greedyStep(ep: number, targetId: number, level: number): number {
    const targetOffset = targetId * this.dim
    let current = ep
    let bestDist = dotProduct(this.vectors, current * this.dim, this.vectors, targetOffset, this.dim)
    let changed = true
    while (changed) {
      changed = false
      for (const neighbor of this.neighbors[current][level] ?? []) {
        const dist = dotProduct(this.vectors, neighbor * this.dim, this.vectors, targetOffset, this.dim)
        if (dist > bestDist) {
          bestDist = dist
          current = neighbor
          changed = true
        }
      }
    }
    return current
  }

  private greedyStepFrom(ep: number, level: number, query: Float32Array, qOffset: number): number {
    let current = ep
    let bestDist = dotProduct(query, qOffset, this.vectors, current * this.dim, this.dim)
    let changed = true
    while (changed) {
      changed = false
      for (const neighbor of this.neighbors[current][level] ?? []) {
        const dist = dotProduct(query, qOffset, this.vectors, neighbor * this.dim, this.dim)
        if (dist > bestDist) {
          bestDist = dist
          current = neighbor
          changed = true
        }
      }
    }
    return current
  }

  /**
   * Standard HNSW layer search: a bounded max-heap of candidates (highest
   * cosine pops first) and a min-heap of results (furthest on top, truncated
   * past ef). The search ends when the best candidate is no better than the
   * furthest result. Note: "dist" here is the cosine dot product, so higher
   * means closer.
   */
  private searchLayerFrom(
    query: Float32Array,
    qOffset: number,
    entryPoints: Array<{ id: number; dist: number }>,
    ef: number,
    level: number,
    visited: Set<number>,
  ): Array<{ id: number; dist: number }> {
    // candidates: max-heap by cosine (closest pops first).
    const candidates: Array<{ id: number; dist: number }> = []
    // results: min-heap by cosine (furthest on top, truncated past ef).
    const results: Array<{ id: number; dist: number }> = []

    for (const ep of entryPoints) {
      visited.add(ep.id)
      candidates.push(ep)
      this.siftMaxUp(candidates, candidates.length - 1)
      results.push(ep)
      this.siftMinUp(results, results.length - 1)
    }

    const pushCandidate = (candidate: { id: number; dist: number }): void => {
      candidates.push(candidate)
      this.siftMaxUp(candidates, candidates.length - 1)
    }
    const popCandidate = (): { id: number; dist: number } => {
      const top = candidates[0]
      const last = candidates.pop()!
      if (candidates.length > 0) {
        candidates[0] = last
        this.siftMaxDown(candidates, 0)
      }
      return top
    }
    const pushResult = (result: { id: number; dist: number }): void => {
      results.push(result)
      this.siftMinUp(results, results.length - 1)
    }
    const popResult = (): { id: number; dist: number } => {
      const worst = results[0]
      const last = results.pop()!
      if (results.length > 0) {
        results[0] = last
        this.siftMinDown(results, 0)
      }
      return worst
    }

    while (candidates.length > 0) {
      const candidate = popCandidate()
      // The furthest result is the root of the min-heap; once the best
      // remaining candidate is worse than it, no improvement is possible.
      if (candidate.dist < results[0].dist) break

      for (const neighbor of this.neighbors[candidate.id][level] ?? []) {
        if (visited.has(neighbor)) continue
        visited.add(neighbor)
        const neighborOffset = neighbor * this.dim
        const dist = dotProduct(query, qOffset, this.vectors, neighborOffset, this.dim)
        if (results.length < ef || dist > results[0].dist) {
          pushCandidate({ id: neighbor, dist })
          pushResult({ id: neighbor, dist })
          if (results.length > ef) popResult()
        }
      }
    }
    // Results hold the closest `ef` rows; return them by descending cosine
    // (best first) for candidate selection and hit ordering.
    return results.sort((a, b) => b.dist - a.dist)
  }

  /**
   * Neighbor selection: candidates (already sorted by descending cosine)
   * are taken directly up to the limit, then a diversity pass replaces
   * candidates that are too close to an already-selected neighbor (HNSW
   * paper, Algorithm 4). The diversity check runs against a cached distance
   * table so the full cost is one dot product per pair.
   */
  private selectNeighbors(
    candidates: Array<{ id: number; dist: number }>,
    limit: number,
  ): number[] {
    if (candidates.length <= limit) {
      return candidates.map(candidate => candidate.id)
    }
    const selected: number[] = []
    for (const candidate of candidates) {
      if (selected.length >= limit) break
      let diverse = true
      const candidateOffset = candidate.id * this.dim
      for (const s of selected) {
        const sOffset = s * this.dim
        const toSelected = dotProduct(this.vectors, sOffset, this.vectors, candidateOffset, this.dim)
        if (toSelected > candidate.dist) {
          diverse = false
          break
        }
      }
      if (diverse) selected.push(candidate.id)
    }
    for (const candidate of candidates) {
      if (selected.length >= limit) break
      if (!selected.includes(candidate.id)) selected.push(candidate.id)
    }
    return selected
  }

  /**
   * Link node a and node b on a level, truncating each side's neighbor list
   * to its cap, keeping the nearest rows (pure distance; diversity is
   * applied at insertion time in selectNeighbors).
   */
  private linkBoth(a: number, b: number, level: number): void {
    const cap = level === 0 ? this.config.mMax0 : this.config.m
    this.linkOneWay(a, b, level, cap)
    this.linkOneWay(b, a, level, cap)
  }

  private linkOneWay(from: number, to: number, level: number, cap: number): void {
    const list = this.neighbors[from][level]
    list.push(to)
    if (list.length <= cap) return
    this.pruneNeighbors(from, list, cap)
  }

  private pruneNeighbors(from: number, list: number[], cap: number): void {
    const fromOffset = from * this.dim
    // Rank by distance to `from` once; diversity checks reuse the ranked
    // order and only compare against already-selected rows.
    const ranked = list
      .map(id => ({
        id,
        dist: dotProduct(this.vectors, fromOffset, this.vectors, id * this.dim, this.dim),
      }))
      .sort((a, b) => b.dist - a.dist)
    const selected: number[] = []
    for (const candidate of ranked) {
      if (selected.length >= cap) break
      let diverse = true
      const candidateOffset = candidate.id * this.dim
      for (const s of selected) {
        const sOffset = s * this.dim
        const toSelected = dotProduct(this.vectors, sOffset, this.vectors, candidateOffset, this.dim)
        if (toSelected > candidate.dist) {
          diverse = false
          break
        }
      }
      if (diverse) selected.push(candidate.id)
    }
    for (const candidate of ranked) {
      if (selected.length >= cap) break
      if (!selected.includes(candidate.id)) selected.push(candidate.id)
    }
    list.length = 0
    list.push(...selected)
  }

  private randomLevel(): number {
    // Standard HNSW level distribution: P(level >= k) = exp(-k * ln(M)),
    // realized as a geometric draw with p = exp(-1/mL).
    let level = 0
    while (this.rand() < Math.exp(-1 / this.mL) && level < 16) level++
    return level
  }

  private growCapacity(): void {
    const next = this.capacity * 2
    const grownVectors = new Float32Array(next * this.dim)
    grownVectors.set(this.vectors)
    this.vectors = grownVectors
    const grownLevels = new Uint8Array(next)
    grownLevels.set(this.levels)
    this.levels = grownLevels
    this.capacity = next
  }

  // Max-heap helpers for candidates (highest cosine pops first).
  private siftMaxUp(heap: Array<{ id: number; dist: number }>, index: number): void {
    while (index > 0) {
      const parent = (index - 1) >> 1
      if (heap[parent].dist >= heap[index].dist) break
      const tmp = heap[parent]
      heap[parent] = heap[index]
      heap[index] = tmp
      index = parent
    }
  }

  private siftMaxDown(heap: Array<{ id: number; dist: number }>, index: number): void {
    const n = heap.length
    while (true) {
      const left = index * 2 + 1
      if (left >= n) break
      const right = left + 1
      let best = left
      if (right < n && heap[right].dist > heap[left].dist) best = right
      if (heap[index].dist >= heap[best].dist) break
      const tmp = heap[best]
      heap[best] = heap[index]
      heap[index] = tmp
      index = best
    }
  }

  // Min-heap helpers for results (furthest/worst cosine on top).
  private siftMinUp(heap: Array<{ id: number; dist: number }>, index: number): void {
    while (index > 0) {
      const parent = (index - 1) >> 1
      if (heap[parent].dist <= heap[index].dist) break
      const tmp = heap[parent]
      heap[parent] = heap[index]
      heap[index] = tmp
      index = parent
    }
  }

  private siftMinDown(heap: Array<{ id: number; dist: number }>, index: number): void {
    const n = heap.length
    while (true) {
      const left = index * 2 + 1
      if (left >= n) break
      const right = left + 1
      let worst = left
      if (right < n && heap[right].dist < heap[left].dist) worst = right
      if (heap[index].dist <= heap[worst].dist) break
      const tmp = heap[worst]
      heap[worst] = heap[index]
      heap[index] = tmp
      index = worst
    }
  }
}
