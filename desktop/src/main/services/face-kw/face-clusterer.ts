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
  const normA = l2Norm(a)
  const normB = l2Norm(b)
  let dot = 0
  for (let i = 0; i < normA.length; i++) {
    dot += normA[i] * normB[i]
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

  const visited = new Array(entries.length).fill(false)
  const assigned = new Array(entries.length).fill(false)
  const clusters: EmbeddingEntry[][] = []
  const noise: EmbeddingEntry[] = []

  for (let i = 0; i < entries.length; i++) {
    if (visited[i]) continue
    visited[i] = true

    const neighbors = regionQuery(entries, i, eps)

    if (neighbors.length < minPts - 1) {
      noise.push(entries[i])
      continue
    }

    const cluster: EmbeddingEntry[] = [entries[i]]
    assigned[i] = true

    const seeds = [...neighbors]
    let seedIdx = 0

    while (seedIdx < seeds.length) {
      const currentIdx = seeds[seedIdx]
      seedIdx++

      if (assigned[currentIdx]) continue

      if (!visited[currentIdx]) {
        visited[currentIdx] = true
        const currentNeighbors = regionQuery(entries, currentIdx, eps)
        if (currentNeighbors.length >= minPts - 1) {
          for (const n of currentNeighbors) {
            if (!visited[n]) {
              seeds.push(n)
            }
          }
        }
      }

      if (!assigned[currentIdx]) {
        assigned[currentIdx] = true
        cluster.push(entries[currentIdx])
      }
    }

    clusters.push(cluster)
  }

  return { clusters, noise }
}
