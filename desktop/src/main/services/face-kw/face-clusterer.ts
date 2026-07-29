export interface EmbeddingEntry {
  observationId: number
  embedding: number[]
  photoId: string
}

function l2Norm(vec: number[]): number[] {
  const sumSq = vec.reduce((s, v) => s + v * v, 0)
  const norm = Math.sqrt(sumSq)
  if (norm === 0) return vec.map(() => 0)
  return vec.map((v) => v / norm)
}

function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i]
  }
  return dot
}

function regionQuery(
  entries: EmbeddingEntry[],
  pointIndex: number,
  eps: number,
): number[] {
  const neighbors: number[] = []
  const pointEmbedding = entries[pointIndex].embedding

  for (let i = 0; i < entries.length; i++) {
    if (i === pointIndex) continue
    const sim = cosineSimilarity(pointEmbedding, entries[i].embedding)
    if (sim >= eps) {
      neighbors.push(i)
    }
  }
  return neighbors
}

export function clusterEmbeddings(
  entries: EmbeddingEntry[],
  eps: number,
  minPts: number,
): { clusters: EmbeddingEntry[][]; noise: EmbeddingEntry[] } {
  if (entries.length === 0) {
    return { clusters: [], noise: [] }
  }

  // Normalize once. The encoder already returns unit vectors, but imported or
  // migrated observations may not; normalizing per comparison made DBSCAN
  // allocate two 512-value arrays for every O(n²) pair.
  const normalizedEntries = entries.map(entry => ({
    ...entry,
    embedding: l2Norm(entry.embedding),
  }))
  const visited = new Array(normalizedEntries.length).fill(false)
  const assigned = new Array(normalizedEntries.length).fill(false)
  const clusters: EmbeddingEntry[][] = []
  const noiseIndices: number[] = []

  for (let i = 0; i < normalizedEntries.length; i++) {
    if (visited[i]) continue
    visited[i] = true

    const neighbors = regionQuery(normalizedEntries, i, eps)

    if (neighbors.length < minPts - 1) {
      noiseIndices.push(i)
      continue
    }

    const cluster: EmbeddingEntry[] = [normalizedEntries[i]]
    assigned[i] = true

    const seeds = [...neighbors]
    const queued = new Set(neighbors)
    let seedIdx = 0

    while (seedIdx < seeds.length) {
      const currentIdx = seeds[seedIdx]
      seedIdx++

      if (assigned[currentIdx]) continue

      if (!visited[currentIdx]) {
        visited[currentIdx] = true
        const currentNeighbors = regionQuery(normalizedEntries, currentIdx, eps)
        if (currentNeighbors.length >= minPts - 1) {
          for (const n of currentNeighbors) {
            if (!visited[n] && !queued.has(n)) {
              queued.add(n)
              seeds.push(n)
            }
          }
        }
      }

      if (!assigned[currentIdx]) {
        assigned[currentIdx] = true
        cluster.push(normalizedEntries[currentIdx])
      }
    }

    clusters.push(cluster)
  }

  const noisePoints = noiseIndices
    .filter(index => !assigned[index])
    .map(index => normalizedEntries[index])
  return { clusters, noise: noisePoints }
}
