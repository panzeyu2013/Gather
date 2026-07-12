import { getDatabase } from '../../db/database'

interface CullingDecisionRow {
  photo_id: string
  decision: string
}

interface OperationLogRow {
  id: number
  operation_type: string
  params: string
  created_at: string
}

export class ReportService {
  generateSessionSummary(sessionId: string): string {
    const db = getDatabase()

    const photos = db
      .prepare('SELECT filename, filepath, status FROM photos WHERE session_id = ?')
      .all(sessionId) as { filename: string; filepath: string; status: string }[]

    let md = '# Session Summary\n\n'
    md += `**Total Photos:** ${photos.length}\n\n`
    md += '| # | Filename | Filepath | Status |\n'
    md += '|---|----------|----------|--------|\n'
    photos.forEach((p, i) => {
      md += `| ${i + 1} | ${p.filename.replace(/\|/g, '\\|')} | ${p.filepath.replace(/\|/g, '\\|')} | ${p.status.replace(/\|/g, '\\|')} |\n`
    })

    return md
  }

  generatePersonReport(sessionId: string): string {
    const db = getDatabase()

    const bindings = db
      .prepare(
        `SELECT rb.role_name, rb.keywords, fc.label, fc.member_count
         FROM role_bindings rb
         JOIN face_clusters fc ON rb.cluster_id = fc.id
         WHERE rb.session_id = ?`,
      )
      .all(sessionId) as { role_name: string; keywords: string; label: string; member_count: number }[]

    let md = '# Person Report\n\n'
    md += `**Bindings:** ${bindings.length}\n\n`
    md += '| Role | Keywords | Cluster | Faces |\n'
    md += '|------|----------|---------|-------|\n'
    for (const b of bindings) {
      const keywords = JSON.parse(b.keywords) as string[]
      md += `| ${b.role_name.replace(/\|/g, '\\|')} | ${keywords.join(', ').replace(/\|/g, '\\|')} | ${b.label.replace(/\|/g, '\\|')} | ${b.member_count} |\n`
    }

    return md
  }

  generateKeywordReport(sessionId: string): string {
    const db = getDatabase()

    const keywordRows = db
      .prepare(
        `SELECT DISTINCT keywords
         FROM role_bindings
         WHERE session_id = ? AND keywords != '[]'`,
      )
      .all(sessionId) as { keywords: string }[]

    const keywordSet = new Set<string>()
    for (const row of keywordRows) {
      try {
        const kw = JSON.parse(row.keywords) as string[]
        for (const k of kw) keywordSet.add(k)
      } catch { /* ignore */ }
    }

    const cullingRows = db
      .prepare('SELECT decision FROM culling_decisions WHERE session_id = ? AND decision != ?')
      .all(sessionId, 'pending') as CullingDecisionRow[]

    const cullingKeywords = new Set<string>()
    for (const row of cullingRows) {
      if (row.decision === 'keep') cullingKeywords.add('culling:keep')
      else if (row.decision === 'reject') cullingKeywords.add('culling:reject')
    }

    const historyRows = db
      .prepare('SELECT operation_type, created_at FROM operation_log WHERE session_id = ? ORDER BY created_at DESC LIMIT 50')
      .all(sessionId) as OperationLogRow[]

    let md = '# Keyword Report\n\n'
    md += '## Face Keywords\n\n'
    if (keywordSet.size === 0) {
      md += '*(none)*\n'
    } else {
      for (const k of Array.from(keywordSet).sort()) {
        md += `- ${k}\n`
      }
    }

    md += '\n## Culling Keywords\n\n'
    if (cullingKeywords.size === 0) {
      md += '*(none)*\n'
    } else {
      for (const k of Array.from(cullingKeywords).sort()) {
        md += `- ${k}\n`
      }
    }

    md += '\n## Recent Operations\n\n'
    if (historyRows.length === 0) {
      md += '*(none)*\n'
    } else {
      md += '| Type | Time |\n'
      md += '|------|------|\n'
      for (const row of historyRows) {
        md += `| ${row.operation_type} | ${row.created_at} |\n`
      }
    }

    return md
  }
}
