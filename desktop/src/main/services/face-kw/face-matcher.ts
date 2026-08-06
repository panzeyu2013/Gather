import type { PersonRepository } from '../../db/repositories/person.repo'
import { CosineLshIndex, LSH_MIN_POINTS } from './lsh-index'

interface LibraryEmbedding {
  personId: string
  embedding: Float32Array
}

interface PersonMatch {
  personId: string
  confidence: number
}

/**
 * Face-to-person-library matcher. For large libraries (> LSH_MIN_POINTS
 * embeddings) the per-query scan is replaced by the shared angular-LSH index:
 * candidate rows are read from the same bucket union used by face clustering
 * and every candidate is re-verified with an exact cosine, so precision is
 * identical to a brute-force scan. Because the LSH stage can only restrict the
 * candidate set, the matched result equals the exact result whenever the true
 * best match is recalled (measured recall >= 0.95 at the quality-gate
 * similarity in face-clusterer-lsh.test.ts); libraries below the threshold
 * keep the exact scan.
 */
export class FaceMatcher {
  private libraryEmbeddings: LibraryEmbedding[] | null = null
  private libraryFlat: Float32Array | null = null
  private lshIndex: CosineLshIndex | null = null
  private libraryDim = 0

  constructor(
    private personRepo: PersonRepository,
    private lshMinPoints: number = LSH_MIN_POINTS,
  ) {}

  private loadLibrary(): LibraryEmbedding[] {
    if (this.libraryEmbeddings) return this.libraryEmbeddings
    const rows = this.personRepo.getAllEmbeddings()
    const embeddings = rows.map((r) => ({
      personId: r.person_id,
      embedding: new Float32Array(r.embedding.buffer, r.embedding.byteOffset, r.embedding.byteLength / 4),
    }))
    this.libraryEmbeddings = embeddings
    if (embeddings.length > this.lshMinPoints) {
      this.libraryDim = embeddings[0].embedding.length
      const flat = new Float32Array(embeddings.length * this.libraryDim)
      for (let i = 0; i < embeddings.length; i++) {
        flat.set(embeddings[i].embedding, i * this.libraryDim)
      }
      this.libraryFlat = flat
      this.lshIndex = new CosineLshIndex(this.libraryDim)
      this.lshIndex.build(flat, embeddings.length)
    }
    return this.libraryEmbeddings
  }

  invalidateCache(): void {
    this.libraryEmbeddings = null
    this.libraryFlat = null
    this.lshIndex = null
  }

  matchAgainstLibrary(
    embeddings: Float32Array[],
    threshold: number,
  ): { matched: Map<number, PersonMatch>; unmatched: number[] } {
    const library = this.loadLibrary()
    const matched = new Map<number, PersonMatch>()
    const unmatched: number[] = []

    if (library.length === 0) {
      for (let i = 0; i < embeddings.length; i++) {
        unmatched.push(i)
      }
      return { matched, unmatched }
    }

    if (this.lshIndex && this.libraryFlat) {
      for (let i = 0; i < embeddings.length; i++) {
        const inputEmb = embeddings[i]
        if (inputEmb.length !== this.libraryDim) {
          throw new Error(`Vector length mismatch: ${inputEmb.length} vs ${this.libraryDim}`)
        }
        const hits = this.lshIndex.neighbors(inputEmb, 0, threshold)
        let bestIndex = -1
        let bestScore = 0
        for (let h = 0; h < hits.count; h++) {
          const score = hits.scores[h]
          if (score > bestScore) {
            bestScore = score
            bestIndex = hits.indices[h]
          }
        }
        if (bestIndex >= 0) {
          matched.set(i, { personId: library[bestIndex].personId, confidence: bestScore })
        } else {
          unmatched.push(i)
        }
      }
      return { matched, unmatched }
    }

    for (let i = 0; i < embeddings.length; i++) {
      const inputEmb = embeddings[i]
      let bestPersonId = ''
      let bestScore = 0

      for (let j = 0; j < library.length; j++) {
        const score = cosineSimilarity(inputEmb, library[j].embedding)
        if (score > bestScore) {
          bestScore = score
          bestPersonId = library[j].personId
        }
      }

      if (bestScore >= threshold && bestPersonId) {
        matched.set(i, { personId: bestPersonId, confidence: bestScore })
      } else {
        unmatched.push(i)
      }
    }

    return { matched, unmatched }
  }
}

function cosineSimilarity(a: Float32Array, b: Float32Array): number {
  if (a.length !== b.length) {
    throw new Error(`Vector length mismatch: ${a.length} vs ${b.length}`)
  }
  const len = a.length
  let dot = 0
  let magA = 0
  let magB = 0
  for (let i = 0; i < len; i++) {
    dot += a[i] * b[i]
    magA += a[i] * a[i]
    magB += b[i] * b[i]
  }
  if (magA === 0 || magB === 0) return 0
  return dot / (Math.sqrt(magA) * Math.sqrt(magB))
}
