import { Database } from '../database'
import crypto from 'crypto'
import { IPersonRepository } from './interfaces'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface PersonRow {
  id: string
  name: string
  keywords: string
  thumbnail_base64: string
  notes: string
  match_threshold: number
  created_at: string
  updated_at: string
}

export interface PersonEmbeddingRow {
  id: number
  person_id: string
  embedding: Buffer
  photo_id: string
  session_id: string
  face_observation_id: number | null
  face_bbox: string
  quality: number
  created_at: string
}

export interface PersonPhotoRow {
  id: number
  person_id: string
  photo_id: string
  session_id: string
  face_bbox: string
  confidence: number
  created_at: string
}

export interface SaveEmbeddingInput {
  personId: string
  embedding: number[]
  photoId: string
  sessionId: string
  faceObservationId: number | null
  faceBbox: number[]
  quality: number
}

export interface PersonUpdateFields {
  name?: string
  keywords?: string[]
  notes?: string
  matchThreshold?: number
}

@injectable()
export class PersonRepository implements IPersonRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  list(): PersonRow[] {
    return this.db.prepare('SELECT * FROM persons ORDER BY name').all() as PersonRow[]
  }

  listWithCounts(): (PersonRow & { photo_count: number; session_count: number })[] {
    return this.db.prepare(`
      SELECT p.*, 
        COALESCE(pp.photo_count, 0) as photo_count,
        COALESCE(pp.session_count, 0) as session_count
      FROM persons p
      LEFT JOIN (
        SELECT person_id, COUNT(*) as photo_count, COUNT(DISTINCT session_id) as session_count
        FROM person_photos
        GROUP BY person_id
      ) pp ON p.id = pp.person_id
      ORDER BY p.name
    `).all() as (PersonRow & { photo_count: number; session_count: number })[]
  }

  get(id: string): PersonRow | undefined {
    return this.db.prepare('SELECT * FROM persons WHERE id = ?').get(id) as PersonRow | undefined
  }

  create(name: string, keywords?: string[]): string {
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    const keywordsJson = JSON.stringify(keywords ?? [])
    this.db.prepare('INSERT INTO persons (id, name, keywords, created_at, updated_at) VALUES (?, ?, ?, ?, ?)').run(
      id,
      name,
      keywordsJson,
      now,
      now,
    )
    return id
  }

  update(id: string, fields: PersonUpdateFields): void {
    const now = new Date().toISOString()
    const sets: string[] = []
    const values: unknown[] = []

    if (fields.name !== undefined) {
      sets.push('name = ?')
      values.push(fields.name)
    }
    if (fields.keywords !== undefined) {
      sets.push('keywords = ?')
      values.push(JSON.stringify(fields.keywords))
    }
    if (fields.notes !== undefined) {
      sets.push('notes = ?')
      values.push(fields.notes)
    }
    if (fields.matchThreshold !== undefined) {
      sets.push('match_threshold = ?')
      values.push(fields.matchThreshold)
    }

    if (sets.length === 0) return

    sets.push('updated_at = ?')
    values.push(now)
    values.push(id)

    this.db.prepare(`UPDATE persons SET ${sets.join(', ')} WHERE id = ?`).run(...values)
  }

  updateThumbnail(id: string, base64: string): void {
    this.db.prepare('UPDATE persons SET thumbnail_base64 = ? WHERE id = ?').run(base64, id)
  }

  delete(id: string): void {
    this.db.prepare('DELETE FROM persons WHERE id = ?').run(id)
  }

  merge(sourceId: string, targetId: string): void {
    const mergeTransaction = this.db.transaction(() => {
      this.db.prepare('UPDATE person_embeddings SET person_id = ? WHERE person_id = ?').run(targetId, sourceId)
      this.db.prepare('UPDATE person_photos SET person_id = ? WHERE person_id = ?').run(targetId, sourceId)
      const mergedKeywords = this.getMergedKeywords(sourceId, targetId)
      const now = new Date().toISOString()
      this.db.prepare('UPDATE persons SET keywords = ?, updated_at = ? WHERE id = ?').run(JSON.stringify(mergedKeywords), now, targetId)

      this.db.prepare('DELETE FROM persons WHERE id = ?').run(sourceId)
    })
    mergeTransaction()
  }

  private getMergedKeywords(sourceId: string, targetId: string): string[] {
    const source = this.db.prepare('SELECT keywords FROM persons WHERE id = ?').get(sourceId) as { keywords: string } | undefined
    const target = this.db.prepare('SELECT keywords FROM persons WHERE id = ?').get(targetId) as { keywords: string } | undefined
    const allKeywords = new Set<string>()
    if (source) {
      try { JSON.parse(source.keywords).forEach((k: string) => allKeywords.add(k)) } catch { /* ignore */ }
    }
    if (target) {
      try { JSON.parse(target.keywords).forEach((k: string) => allKeywords.add(k)) } catch { /* ignore */ }
    }
    return Array.from(allKeywords)
  }

  getPhotos(personId: string, sessionIds?: string[], limit?: number, offset?: number): PersonPhotoRow[] {
    let sql = 'SELECT * FROM person_photos WHERE person_id = ?'
    const params: unknown[] = [personId]
    if (sessionIds && sessionIds.length > 0) {
      sql += ` AND session_id IN (${sessionIds.map(() => '?').join(',')})`
      params.push(...sessionIds)
    }
    sql += ' ORDER BY created_at DESC'
    if (typeof limit === 'number') {
      sql += ' LIMIT ?'
      params.push(limit)
    }
    if (typeof offset === 'number') {
      sql += ' OFFSET ?'
      params.push(offset)
    }
    return this.db.prepare(sql).all(...params) as PersonPhotoRow[]
  }

  removePhoto(personId: string, photoId: string): void {
    const removeTransaction = this.db.transaction(() => {
      this.db.prepare('DELETE FROM person_photos WHERE person_id = ? AND photo_id = ?').run(personId, photoId)
      this.db.prepare('DELETE FROM person_embeddings WHERE person_id = ? AND photo_id = ?').run(personId, photoId)
    })
    removeTransaction()
  }

  getPersonPhoto(personId: string, photoId: string): PersonPhotoRow | undefined {
    return this.db.prepare('SELECT * FROM person_photos WHERE person_id = ? AND photo_id = ?').get(personId, photoId) as PersonPhotoRow | undefined
  }

  addPhoto(personId: string, photoId: string, sessionId: string, faceBbox: number[], confidence: number): void {
    const now = new Date().toISOString()
    this.db.prepare('INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)').run(
      personId,
      photoId,
      sessionId,
      JSON.stringify(faceBbox),
      confidence,
      now,
    )
  }

  saveEmbeddings(embeddings: SaveEmbeddingInput[]): void {
    const now = new Date().toISOString()
    const stmt = this.db.prepare(
      'INSERT OR REPLACE INTO person_embeddings (person_id, embedding, photo_id, session_id, face_observation_id, face_bbox, quality, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    )
    const insertMany = this.db.transaction(() => {
      for (const emb of embeddings) {
        const embBuffer = Buffer.from(new Float32Array(emb.embedding).buffer)
        stmt.run(emb.personId, embBuffer, emb.photoId, emb.sessionId, emb.faceObservationId, JSON.stringify(emb.faceBbox), emb.quality, now)
      }
    })
    insertMany()
  }

  deleteEmbeddingsByObservationIds(observationIds: number[]): void {
    if (observationIds.length === 0) return
    const placeholders = observationIds.map(() => '?').join(',')
    this.db.prepare(`DELETE FROM person_embeddings WHERE face_observation_id IN (${placeholders})`).run(...observationIds)
  }

  getAllEmbeddings(): { person_id: string; embedding: Buffer; face_observation_id: number | null }[] {
    return this.db.prepare('SELECT person_id, embedding, face_observation_id FROM person_embeddings').all() as { person_id: string; embedding: Buffer; face_observation_id: number | null }[]
  }

  getEmbeddingsByPerson(personId: string): PersonEmbeddingRow[] {
    return this.db.prepare('SELECT * FROM person_embeddings WHERE person_id = ? ORDER BY id').all(personId) as PersonEmbeddingRow[]
  }

  deleteEmbeddingsByPerson(personId: string): void {
    this.db.prepare('DELETE FROM person_embeddings WHERE person_id = ?').run(personId)
  }

  countEmbeddings(personId: string): number {
    const row = this.db.prepare('SELECT COUNT(*) as count FROM person_embeddings WHERE person_id = ?').get(personId) as { count: number }
    return row.count
  }

  countPhotos(personId: string): number {
    const row = this.db.prepare('SELECT COUNT(*) as count FROM person_photos WHERE person_id = ?').get(personId) as { count: number }
    return row.count
  }

  getSessionCount(personId: string): number {
    const row = this.db.prepare('SELECT COUNT(DISTINCT session_id) as count FROM person_photos WHERE person_id = ?').get(personId) as { count: number }
    return row.count
  }

  getThumbnailBase64(personId: string): string {
    const row = this.db.prepare('SELECT thumbnail_base64 FROM persons WHERE id = ?').get(personId) as { thumbnail_base64: string } | undefined
    return row?.thumbnail_base64 ?? ''
  }

  getPhotosWithDetails(
    personId: string,
    sessionIds?: string[],
    limit?: number,
    offset?: number,
  ): { photos: (PersonPhotoRow & { sessionName: string; filename: string; filepath: string })[], total: number } {
    let whereClause = 'pp.person_id = ?'
    const params: unknown[] = [personId]
    if (sessionIds && sessionIds.length > 0) {
      whereClause += ` AND pp.session_id IN (${sessionIds.map(() => '?').join(',')})`
      params.push(...sessionIds)
    }

    const countRow = this.db.prepare(
      `SELECT COUNT(*) as count FROM person_photos pp WHERE ${whereClause}`,
    ).get(...params) as { count: number }

    let sql = `
      SELECT pp.*, s.name as session_name, p.filename, p.filepath
      FROM person_photos pp
      JOIN sessions s ON pp.session_id = s.id
      JOIN photos p ON pp.photo_id = p.id
      WHERE ${whereClause}
      ORDER BY pp.created_at DESC
    `
    const queryParams = [...params]
    if (typeof limit === 'number') {
      sql += ' LIMIT ?'
      queryParams.push(limit)
    }
    if (typeof offset === 'number') {
      sql += ' OFFSET ?'
      queryParams.push(offset)
    }

    const photos = this.db.prepare(sql).all(...queryParams) as (PersonPhotoRow & { session_name: string; filename: string; filepath: string })[]
    return {
      photos: photos.map(p => ({ ...p, sessionName: p.session_name, filename: p.filename, filepath: p.filepath })),
      total: countRow.count,
    }
  }
}
