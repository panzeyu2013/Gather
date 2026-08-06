import {
  CosineLshIndex,
  DEFAULT_LSH_CONFIG,
  LSH_MIN_POINTS,
  type LshIndexConfig,
} from './lsh-index'

export interface EmbeddingEntry {
  observationId: number
  embedding: number[] | Float32Array
  photoId: string
}

export type ClusterProgressCallback = (current: number, total: number) => void

/**
 * ANN gating for clustering. When `enabled` and the observation count exceeds
 * `minPoints`, DBSCAN region queries go through the angular-LSH index (buckets
 * + multi-probe + exact cosine verification) instead of a full O(n^2) scan.
 * Quality-gate measurements (ARI/NMI vs the exact path at n = 50_000) decide
 * whether the ANN path stays the default; see tests/unit/services/face-kw/
 * face-clusterer-lsh.test.ts.
 */
export interface ClusterLshOptions {
  enabled: boolean
  minPoints: number
  config: LshIndexConfig
}

export const DEFAULT_CLUSTER_LSH_OPTIONS: ClusterLshOptions = {
  enabled: true,
  minPoints: LSH_MIN_POINTS,
  config: { ...DEFAULT_LSH_CONFIG, unitVectors: true },
}

// Dot product over two rows of a row-major flat Float32Array. Rows are
// accessed sequentially, so the inner loop touches 512 consecutive floats —
// cache-friendly and free of per-comparison allocations.
function rowDotProduct(
  flat: Float32Array,
  dim: number,
  aOffset: number,
  bOffset: number,
): number {
  let dot = 0
  let k = 0
  for (; k + 4 <= dim; k += 4) {
    dot +=
      flat[aOffset + k] * flat[bOffset + k] +
      flat[aOffset + k + 1] * flat[bOffset + k + 1] +
      flat[aOffset + k + 2] * flat[bOffset + k + 2] +
      flat[aOffset + k + 3] * flat[bOffset + k + 3]
  }
  for (; k < dim; k++) {
    dot += flat[aOffset + k] * flat[bOffset + k]
  }
  return dot
}

function normalizeRows(flat: Float32Array, n: number, dim: number): void {
  for (let i = 0; i < n; i++) {
    const offset = i * dim
    let sumSq = 0
    for (let k = 0; k < dim; k++) {
      const value = flat[offset + k]
      sumSq += value * value
    }
    const norm = Math.sqrt(sumSq)
    if (norm === 0) continue
    const invNorm = 1 / norm
    for (let k = 0; k < dim; k++) {
      flat[offset + k] *= invNorm
    }
  }
}

function exactRegionQuery(
  flat: Float32Array,
  n: number,
  dim: number,
  pointIndex: number,
  eps: number,
): number[] {
  const neighbors: number[] = []
  const pointOffset = pointIndex * dim
  for (let i = 0; i < n; i++) {
    if (i === pointIndex) continue
    if (rowDotProduct(flat, dim, pointOffset, i * dim) >= eps) {
      neighbors.push(i)
    }
  }
  return neighbors
}

export function clusterEmbeddings(
  entries: EmbeddingEntry[],
  eps: number,
  minPts: number,
  onProgress?: ClusterProgressCallback,
  lshOptions?: Partial<ClusterLshOptions>,
): { clusters: EmbeddingEntry[][]; noise: EmbeddingEntry[] } {
  const n = entries.length
  if (n === 0) {
    return { clusters: [], noise: [] }
  }

  // The encoder already returns unit vectors, but imported or migrated
  // observations may not; normalize once into a single flat Float32Array
  // instead of allocating per-comparison copies.
  const dim = entries[0].embedding.length
  const flat = new Float32Array(n * dim)
  for (let i = 0; i < n; i++) {
    const source = entries[i].embedding
    if (source.length !== dim) {
      throw new Error(
        `Embedding dimension mismatch: expected ${dim}, received ${source.length}`,
      )
    }
    flat.set(source, i * dim)
  }
  normalizeRows(flat, n, dim)

  // ANN region queries for large corpora: bucket the rows once, then let every
  // regionQuery reuse the index (multi-probe buckets + exact verification).
  // Small corpora keep the exact O(n) scan, which is both faster in absolute
  // terms and produces the reference result shape.
  const options: ClusterLshOptions = { ...DEFAULT_CLUSTER_LSH_OPTIONS, ...lshOptions }
  let index: CosineLshIndex | null = null
  if (options.enabled && n > options.minPoints) {
    index = new CosineLshIndex(dim, options.config)
    index.build(flat, n)
  }

  const regionQuery = (pointIndex: number): number[] => {
    if (!index) {
      return exactRegionQuery(flat, n, dim, pointIndex, eps)
    }
    const hits = index.neighbors(flat, pointIndex * dim, eps)
    const neighbors: number[] = []
    for (let h = 0; h < hits.count; h++) {
      const candidate = hits.indices[h]
      if (candidate !== pointIndex) neighbors.push(candidate)
    }
    return neighbors
  }

  const visited = new Uint8Array(n)
  const assigned = new Uint8Array(n)
  const clusters: EmbeddingEntry[][] = []
  const noiseIndices: number[] = []
  const minNeighbors = minPts - 1
  const progressStep = Math.max(1, Math.round(n / 20))

  for (let i = 0; i < n; i++) {
    if (i % progressStep === 0) {
      onProgress?.(i, n)
    }
    if (visited[i]) continue
    visited[i] = 1

    const neighbors = regionQuery(i)

    if (neighbors.length < minNeighbors) {
      noiseIndices.push(i)
      continue
    }

    const cluster: EmbeddingEntry[] = [entries[i]]
    assigned[i] = 1

    const seeds = neighbors
    const queued = new Uint8Array(n)
    for (const seed of neighbors) queued[seed] = 1
    let seedIdx = 0

    while (seedIdx < seeds.length) {
      const currentIdx = seeds[seedIdx]
      seedIdx++

      if (assigned[currentIdx]) continue

      if (!visited[currentIdx]) {
        visited[currentIdx] = 1
        const currentNeighbors = regionQuery(currentIdx)
        if (currentNeighbors.length >= minNeighbors) {
          for (const candidate of currentNeighbors) {
            if (!visited[candidate] && !queued[candidate]) {
              queued[candidate] = 1
              seeds.push(candidate)
            }
          }
        }
      }

      if (!assigned[currentIdx]) {
        assigned[currentIdx] = 1
        cluster.push(entries[currentIdx])
      }
    }

    clusters.push(cluster)
  }
  onProgress?.(n, n)

  const noise = noiseIndices
    .filter(index => !assigned[index])
    .map(index => entries[index])
  return { clusters, noise }
}
