import { getDatabase } from '../../db/database'
import crypto from 'crypto'
import type { TemplateData, WorkflowTemplateConfig } from '@gather/shared'

interface TemplateRow {
  id: string
  name: string
  description: string
  config: string
  created_at: string
  updated_at: string
}

function rowToData(row: TemplateRow): TemplateData {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    config: JSON.parse(row.config) as WorkflowTemplateConfig,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

export class TemplateService {
  list(): TemplateData[] {
    const db = getDatabase()
    const rows = db.prepare('SELECT * FROM workflow_templates ORDER BY updated_at DESC').all() as TemplateRow[]
    return rows.map(rowToData)
  }

  get(id: string): TemplateData | null {
    const db = getDatabase()
    const row = db.prepare('SELECT * FROM workflow_templates WHERE id = ?').get(id) as TemplateRow | undefined
    return row ? rowToData(row) : null
  }

  create(name: string, description: string, config: WorkflowTemplateConfig): TemplateData {
    const db = getDatabase()
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    db.prepare(
      'INSERT INTO workflow_templates (id, name, description, config, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
    ).run(id, name, description, JSON.stringify(config), now, now)
    return this.get(id)!
  }

  update(
    id: string,
    fields: Partial<{ name: string; description: string; config: WorkflowTemplateConfig }>,
  ): TemplateData {
    const db = getDatabase()
    const existing = this.get(id)
    if (!existing) throw new Error('Template not found')

    const now = new Date().toISOString()
    const sets: string[] = []
    const values: unknown[] = []

    if (fields.name !== undefined) {
      sets.push('name = ?')
      values.push(fields.name)
    }
    if (fields.description !== undefined) {
      sets.push('description = ?')
      values.push(fields.description)
    }
    if (fields.config !== undefined) {
      sets.push('config = ?')
      values.push(JSON.stringify(fields.config))
    }

    if (sets.length === 0) return existing

    sets.push('updated_at = ?')
    values.push(now)
    values.push(id)

    db.prepare(`UPDATE workflow_templates SET ${sets.join(', ')} WHERE id = ?`).run(...values)
    return this.get(id)!
  }

  delete(id: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM workflow_templates WHERE id = ?').run(id)
  }

  apply(templateId: string, sessionId: string): void {
    const template = this.get(templateId)
    if (!template) throw new Error('Template not found')

    const db = getDatabase()
    const session = db.prepare('SELECT status FROM sessions WHERE id = ?').get(sessionId) as { status: string } | undefined
    if (!session) throw new Error('Session not found')

    const allowed = ['draft', 'photos_loaded']
    if (!allowed.includes(session.status)) {
      throw new Error(`Cannot apply template to session with status "${session.status}". Expected draft or photos_loaded.`)
    }

    const config = template.config

    db.transaction(() => {
      // similarity settings
      db.prepare(`INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .run('default_threshold', String(config.similarity.threshold))
      db.prepare(`INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .run('default_min_group_size', String(config.similarity.minGroupSize))

      // face settings
      db.prepare(`INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .run('default_eps', String(config.face.eps))
      db.prepare(`INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .run('default_min_samples', String(config.face.minSamples))
      db.prepare(`INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .run('detect_confidence', String(config.face.detectorConfidence))
    })()
  }
}
