import { Database } from '../../db/database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import type { AppLocale } from '../../locale'
import { mainCopy } from '../../locale-copy'

interface CullingDecisionRow {
  photo_id: string
  decision: string
}

@injectable()
export class ReportService {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  generateSessionSummary(sessionId: string, locale: AppLocale): string {
    const photos = this.db
      .prepare('SELECT filename, filepath, status FROM photos WHERE session_id = ?')
      .all(sessionId) as { filename: string; filepath: string; status: string }[]

    const r = mainCopy(locale).reports.sessionSummary
    let md = `${r.title}\n\n`
    md += `${r.totalPhotos} ${photos.length}\n\n`
    md += `${r.tableHeader}\n`
    md += '|---|----------|----------|--------|\n'
    photos.forEach((p, i) => {
      md += `| ${i + 1} | ${p.filename.replace(/\|/g, '\\|')} | ${p.filepath.replace(/\|/g, '\\|')} | ${p.status.replace(/\|/g, '\\|')} |\n`
    })

    return md
  }

  generatePersonReport(sessionId: string, locale: AppLocale): string {
    const bindings = this.db
      .prepare(
        `SELECT rb.role_name, rb.keywords, fc.label, fc.member_count
         FROM role_bindings rb
         JOIN face_clusters fc ON rb.cluster_id = fc.id
         WHERE rb.session_id = ?`,
      )
      .all(sessionId) as { role_name: string; keywords: string; label: string; member_count: number }[]

    const r = mainCopy(locale).reports.personReport
    let md = `${r.title}\n\n`
    md += `${r.bindingCount} ${bindings.length}\n\n`
    md += `${r.tableHeader}\n`
    md += '|------|----------|---------|-------|\n'
    for (const b of bindings) {
      const keywords = JSON.parse(b.keywords) as string[]
      md += `| ${b.role_name.replace(/\|/g, '\\|')} | ${keywords.join(', ').replace(/\|/g, '\\|')} | ${b.label.replace(/\|/g, '\\|')} | ${b.member_count} |\n`
    }

    return md
  }

  generateKeywordReport(sessionId: string, locale: AppLocale): string {
    const keywordRows = this.db
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

    const cullingRows = this.db
      .prepare('SELECT decision FROM culling_decisions WHERE session_id = ? AND decision != ?')
      .all(sessionId, 'pending') as CullingDecisionRow[]

    const cullingKeywords = new Set<string>()
    for (const row of cullingRows) {
      if (row.decision === 'keep') cullingKeywords.add('culling:keep')
      else if (row.decision === 'reject') cullingKeywords.add('culling:reject')
    }

    const r = mainCopy(locale).reports.keywordReport
    let md = `${r.title}\n\n`
    md += `${r.faceKeywords}\n\n`
    if (keywordSet.size === 0) {
      md += `${r.none}\n`
    } else {
      for (const k of Array.from(keywordSet).sort()) {
        md += `- ${k}\n`
      }
    }

    md += `\n${r.cullingKeywords}\n\n`
    if (cullingKeywords.size === 0) {
      md += `${r.none}\n`
    } else {
      for (const k of Array.from(cullingKeywords).sort()) {
        md += `- ${k}\n`
      }
    }

    return md
  }
}
