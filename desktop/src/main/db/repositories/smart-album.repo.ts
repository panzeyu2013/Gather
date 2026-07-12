import { getDatabase } from '../database'
import crypto from 'crypto'
import type { FilterGroup } from '@gather/shared'

export interface SmartAlbumRow {
  id: string
  name: string
  description: string
  filter_criteria: string
  sort_by: string
  sort_order: string
  icon: string
  created_at: string
  updated_at: string
}

export interface SmartAlbumCreateData {
  name: string
  description?: string
  filterCriteria: FilterGroup
  sortBy?: string
  sortOrder?: string
  icon?: string
}

export interface SmartAlbumUpdateData {
  name?: string
  description?: string
  filterCriteria?: FilterGroup
  sortBy?: string
  sortOrder?: string
  icon?: string
}

export class SmartAlbumRepository {
  list(): SmartAlbumRow[] {
    const db = getDatabase()
    return db.prepare('SELECT * FROM smart_albums ORDER BY updated_at DESC').all() as SmartAlbumRow[]
  }

  get(id: string): SmartAlbumRow | undefined {
    const db = getDatabase()
    return db.prepare('SELECT * FROM smart_albums WHERE id = ?').get(id) as SmartAlbumRow | undefined
  }

  create(data: SmartAlbumCreateData): SmartAlbumRow {
    const db = getDatabase()
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    db.prepare(
      'INSERT INTO smart_albums (id, name, description, filter_criteria, sort_by, sort_order, icon, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run(
      id,
      data.name,
      data.description ?? '',
      JSON.stringify(data.filterCriteria),
      data.sortBy ?? 'date_taken',
      data.sortOrder ?? 'desc',
      data.icon ?? '📁',
      now,
      now,
    )
    return this.get(id)!
  }

  update(id: string, data: SmartAlbumUpdateData): void {
    const db = getDatabase()
    const now = new Date().toISOString()
    const sets: string[] = []
    const values: unknown[] = []

    if (data.name !== undefined) {
      sets.push('name = ?')
      values.push(data.name)
    }
    if (data.description !== undefined) {
      sets.push('description = ?')
      values.push(data.description)
    }
    if (data.filterCriteria !== undefined) {
      sets.push('filter_criteria = ?')
      values.push(JSON.stringify(data.filterCriteria))
    }
    if (data.sortBy !== undefined) {
      sets.push('sort_by = ?')
      values.push(data.sortBy)
    }
    if (data.sortOrder !== undefined) {
      sets.push('sort_order = ?')
      values.push(data.sortOrder)
    }
    if (data.icon !== undefined) {
      sets.push('icon = ?')
      values.push(data.icon)
    }

    if (sets.length === 0) return

    sets.push('updated_at = ?')
    values.push(now)
    values.push(id)

    db.prepare(`UPDATE smart_albums SET ${sets.join(', ')} WHERE id = ?`).run(...values)
  }

  delete(id: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM smart_albums WHERE id = ?').run(id)
  }
}
