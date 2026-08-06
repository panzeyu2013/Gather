// Angular LSH (random-projection / SimHash) index shared by face clustering
// and person-library matching.
//
// Vectors are hashed by the signs of their projections onto random Gaussian
// hyperplanes: two unit vectors collide in a bucket with probability
// 1 - arccos(sim) / pi per bit, so nearby points share buckets far more often
// than distant ones. Multiple tables (each with its own hyperplane set) plus
// multi-probe (probing the Hamming neighbourhood of the query bucket) recover
// recall for cosine thresholds down to ~0.6 while keeping the candidate set a
// tiny fraction of the corpus. Every candidate is re-verified with an exact
// cosine comparison, so false positives can never leak into results — LSH only
// ever *restricts* the candidate set.
//
// All random material (hyperplanes) is drawn from a seeded PRNG, so identical
// input yields identical hashes, buckets and results across runs.
//
// The query path is allocation-free: hit rows are written into scratch typed
// arrays owned by the index and exposed through a small LshHits view. Callers
// must consume the hits before the next neighbors() call on the same index.

export interface LshIndexConfig {
  /** Hash bits per table; the bucket count per table is 2^bits. */
  bits: number
  /** Number of independent hash tables. */
  tables: number
  /** Multi-probe radius: also probe buckets up to `probeRadius` Hamming flips away. */
  probeRadius: number
  /** Deterministic seed for hyperplane generation. */
  seed: number
  /**
   * When true the indexed rows are known unit vectors (e.g. the clustering
   * pipeline normalizes them) and the exact verification compares the raw dot
   * product — identical to the exact-path comparison, including float-level
   * behaviour at the eps boundary. When false a full cosine (with magnitudes)
   * is computed, matching the historical person-matcher semantics.
   */
  unitVectors?: boolean
}

export const DEFAULT_LSH_CONFIG: LshIndexConfig = {
  bits: 16,
  tables: 6,
  probeRadius: 2,
  seed: 0xf4ce0b5e,
  unitVectors: false,
}

/** Above this many rows the ANN path is used instead of the O(n^2) scan. */
export const LSH_MIN_POINTS = 20_000

/** Scratch view returned by CosineLshIndex.neighbors. Only the first `count`
 * entries of `indices`/`scores` are valid, and they stay valid until the next
 * neighbors() call on the same index. */
export interface LshHits {
  count: number
  /** Candidate row indices into the indexed flat array. */
  indices: Uint32Array
  /** Exact cosine (or dot product for unit vectors) aligned with `indices`. */
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

function gaussian(rand: () => number): number {
  let u = 0
  do { u = rand() } while (u === 0)
  const v = rand()
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
}

/** All Hamming masks up to `radius` bit flips (probeRadius <= 2). */
function buildProbeMasks(bits: number, radius: number): number[] {
  const masks = [0]
  for (let i = 0; i < bits; i++) masks.push(1 << i)
  if (radius >= 2) {
    for (let i = 0; i < bits; i++) {
      for (let j = i + 1; j < bits; j++) masks.push((1 << i) | (1 << j))
    }
  }
  return masks
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

export class CosineLshIndex {
  readonly config: LshIndexConfig
  private readonly dim: number
  private readonly planes: Float32Array[]
  private readonly probeMasks: number[]
  private readonly unitVectors: boolean

  private count = 0
  private rows: Float32Array | null = null
  private starts: Uint32Array[] = []
  private members: Uint32Array[] = []
  private visited: Uint32Array = new Uint32Array(0)
  private candidateScratch: Uint32Array = new Uint32Array(0)
  private hitIndices: Uint32Array = new Uint32Array(0)
  private hitScores: Float32Array = new Float32Array(0)
  private hits: LshHits = { count: 0, indices: this.hitIndices, scores: this.hitScores }
  private queryStamp = 1

  constructor(dim: number, config: LshIndexConfig = DEFAULT_LSH_CONFIG) {
    if (!Number.isInteger(dim) || dim <= 0) {
      throw new Error(`LSH dimension must be a positive integer, received ${dim}`)
    }
    if (!Number.isInteger(config.bits) || config.bits < 6 || config.bits > 22) {
      throw new Error(`LSH bits must be an integer in [6, 22], received ${config.bits}`)
    }
    if (!Number.isInteger(config.tables) || config.tables < 1) {
      throw new Error(`LSH tables must be a positive integer, received ${config.tables}`)
    }
    if (!Number.isInteger(config.probeRadius) || config.probeRadius < 0 || config.probeRadius > 2) {
      throw new Error(`LSH probeRadius must be an integer in [0, 2], received ${config.probeRadius}`)
    }
    this.dim = dim
    this.config = config
    this.unitVectors = config.unitVectors ?? false
    this.probeMasks = buildProbeMasks(config.bits, config.probeRadius)

    this.planes = []
    for (let t = 0; t < config.tables; t++) {
      const rand = mulberry32((config.seed ^ Math.imul(t + 1, 0x9e3779b9)) >>> 0)
      const plane = new Float32Array(config.bits * dim)
      for (let i = 0; i < plane.length; i++) plane[i] = gaussian(rand)
      this.planes.push(plane)
    }
  }

  get size(): number {
    return this.count
  }

  private hashRow(plane: Float32Array, row: Float32Array, rowOffset: number): number {
    const dim = this.dim
    const bits = this.config.bits
    let hash = 0
    for (let k = 0; k < bits; k++) {
      const base = k * dim
      const dot = dotProduct(plane, base, row, rowOffset, dim)
      if (dot >= 0) hash |= 1 << k
    }
    return hash >>> 0
  }

  /** Hash every row of a row-major flat array and build the bucket tables. */
  build(rows: Float32Array, count: number): void {
    if (rows.length !== count * this.dim) {
      throw new Error(
        `LSH build shape mismatch: ${count} rows of dim ${this.dim} needs ${count * this.dim} floats, received ${rows.length}`,
      )
    }
    this.count = count
    this.rows = rows
    this.visited = new Uint32Array(count)
    this.candidateScratch = new Uint32Array(count)
    this.hitIndices = new Uint32Array(count)
    this.hitScores = new Float32Array(count)
    this.hits = { count: 0, indices: this.hitIndices, scores: this.hitScores }
    this.queryStamp = 1
    const buckets = 1 << this.config.bits
    this.starts = []
    this.members = []
    for (let t = 0; t < this.config.tables; t++) {
      const plane = this.planes[t]
      const hashes = new Uint32Array(count)
      for (let i = 0; i < count; i++) hashes[i] = this.hashRow(plane, rows, i * this.dim)

      const counts = new Uint32Array(buckets)
      for (let i = 0; i < count; i++) counts[hashes[i]]++

      const starts = new Uint32Array(buckets + 1)
      let acc = 0
      for (let b = 0; b < buckets; b++) {
        starts[b] = acc
        acc += counts[b]
      }
      starts[buckets] = acc

      const members = new Uint32Array(count)
      const cursor = new Uint32Array(buckets)
      for (let b = 0; b < buckets; b++) cursor[b] = starts[b]
      for (let i = 0; i < count; i++) {
        const bucket = hashes[i]
        members[cursor[bucket]++] = i
      }
      this.starts.push(starts)
      this.members.push(members)
    }
  }

  /**
   * Return every indexed row whose exact cosine (or dot product for unit
   * vectors) with the query row is >= `threshold`, deduplicated across the
   * probe buckets of all tables. The query may live inside the indexed array
   * (clustering) or in a separate buffer (matching); `queryOffset` is the row
   * offset in floats. The returned LshHits points at scratch storage owned by
   * the index — it is only valid until the next call on the same index.
   */
  neighbors(query: Float32Array, queryOffset: number, threshold: number): LshHits {
    if (this.count === 0) {
      this.hits.count = 0
      return this.hits
    }
    if (query.length - queryOffset < this.dim) {
      throw new Error(
        `LSH query shape mismatch: expected dim ${this.dim}, received ${query.length - queryOffset} floats`,
      )
    }
    const rows = this.rows
    if (!rows) throw new Error('LSH index has no rows; call build() first')

    // Generation stamping avoids resetting the visited array per query.
    const stamp = this.queryStamp++
    if (stamp === 0) {
      this.visited.fill(0)
      this.queryStamp = 1
    }

    // Collect unique candidate rows first, then verify them in row order.
    // Bucket-scan order touches rows randomly; a sorted pass streams rows
    // sequentially, which is several times faster on large corpora.
    const candidates = this.candidateScratch
    let candidateCount = 0
    for (let t = 0; t < this.config.tables; t++) {
      const hash = this.hashRow(this.planes[t], query, queryOffset)
      const starts = this.starts[t]
      const members = this.members[t]
      for (let m = 0; m < this.probeMasks.length; m++) {
        const bucket = hash ^ this.probeMasks[m]
        const from = starts[bucket]
        const to = starts[bucket + 1]
        for (let p = from; p < to; p++) {
          const candidate = members[p]
          if (this.visited[candidate] === stamp) continue
          this.visited[candidate] = stamp
          candidates[candidateCount++] = candidate
        }
      }
    }
    candidates.subarray(0, candidateCount).sort()

    this.hits.count = verifyCandidates(
      query,
      queryOffset,
      rows,
      this.dim,
      threshold,
      this.unitVectors,
      candidates,
      candidateCount,
      this.hitIndices,
      this.hitScores,
    )
    return this.hits
  }
}

// Extracted as a module-level function so the hot loop is small enough for V8
// to fully optimize; inside the method it ran several times slower. Writes go
// straight into caller-owned scratch typed arrays (no per-hit allocations).
function verifyCandidates(
  query: Float32Array,
  queryOffset: number,
  rows: Float32Array,
  dim: number,
  threshold: number,
  unitVectors: boolean,
  candidates: Uint32Array,
  candidateCount: number,
  hitIndices: Uint32Array,
  hitScores: Float32Array,
): number {
  let hitCount = 0
  for (let c = 0; c < candidateCount; c++) {
    const candidate = candidates[c]
    const rowOffset = candidate * dim
    let score: number
    if (unitVectors) {
      score = dotProduct(query, queryOffset, rows, rowOffset, dim)
      if (score < threshold) continue
    } else {
      let dot = 0
      let magQ = 0
      let magR = 0
      let k = 0
      for (; k + 4 <= dim; k += 4) {
        const q0 = query[queryOffset + k]
        const q1 = query[queryOffset + k + 1]
        const q2 = query[queryOffset + k + 2]
        const q3 = query[queryOffset + k + 3]
        const r0 = rows[rowOffset + k]
        const r1 = rows[rowOffset + k + 1]
        const r2 = rows[rowOffset + k + 2]
        const r3 = rows[rowOffset + k + 3]
        dot += q0 * r0 + q1 * r1 + q2 * r2 + q3 * r3
        magQ += q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3
        magR += r0 * r0 + r1 * r1 + r2 * r2 + r3 * r3
      }
      for (; k < dim; k++) {
        const q = query[queryOffset + k]
        const r = rows[rowOffset + k]
        dot += q * r
        magQ += q * q
        magR += r * r
      }
      if (magQ === 0 || magR === 0) continue
      score = dot / (Math.sqrt(magQ) * Math.sqrt(magR))
      if (score < threshold) continue
    }
    hitIndices[hitCount] = candidate
    hitScores[hitCount] = score
    hitCount++
  }
  return hitCount
}
