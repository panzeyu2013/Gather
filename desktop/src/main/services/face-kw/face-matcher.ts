import type { PersonRepository } from '../../db/repositories/person.repo'

interface LibraryEmbedding {
  personId: string
  embedding: Float32Array
}

interface PersonMatch {
  personId: string
  confidence: number
}

export class FaceMatcher {
  private libraryEmbeddings: LibraryEmbedding[] | null = null

  constructor(private personRepo: PersonRepository) {}

  private loadLibrary(): LibraryEmbedding[] {
    if (this.libraryEmbeddings) return this.libraryEmbeddings
    const rows = this.personRepo.getAllEmbeddings()
    this.libraryEmbeddings = rows.map((r) => ({
      personId: r.person_id,
      embedding: new Float32Array(r.embedding.buffer, r.embedding.byteOffset, r.embedding.byteLength / 4),
    }))
    return this.libraryEmbeddings
  }

  invalidateCache(): void {
    this.libraryEmbeddings = null
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
