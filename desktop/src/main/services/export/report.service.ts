import { Database } from '../../db/database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

interface CullingDecisionRow {
  photo_id: string
  decision: string
}

@injectable()
export class ReportService {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  generateSessionSummary(sessionId: string): string {
    const photos = this.db
      .prepare('SELECT filename, filepath, status FROM photos WHERE session_id = ?')
      .all(sessionId) as { filename: string; filepath: string; status: string }[]

    let md = '# 工作区摘要\n\n'
    md += `**照片总数：** ${photos.length}\n\n`
    md += '| # | 文件名 | 文件路径 | 状态 |\n'
    md += '|---|----------|----------|--------|\n'
    photos.forEach((p, i) => {
      md += `| ${i + 1} | ${p.filename.replace(/\|/g, '\\|')} | ${p.filepath.replace(/\|/g, '\\|')} | ${p.status.replace(/\|/g, '\\|')} |\n`
    })

    return md
  }

  generatePersonReport(sessionId: string): string {
    const bindings = this.db
      .prepare(
        `SELECT rb.role_name, rb.keywords, fc.label, fc.member_count
         FROM role_bindings rb
         JOIN face_clusters fc ON rb.cluster_id = fc.id
         WHERE rb.session_id = ?`,
      )
      .all(sessionId) as { role_name: string; keywords: string; label: string; member_count: number }[]

    let md = '# 人物报告\n\n'
    md += `**绑定数量：** ${bindings.length}\n\n`
    md += '| 角色 | 关键词 | 人脸组 | 人脸数量 |\n'
    md += '|------|----------|---------|-------|\n'
    for (const b of bindings) {
      const keywords = JSON.parse(b.keywords) as string[]
      md += `| ${b.role_name.replace(/\|/g, '\\|')} | ${keywords.join(', ').replace(/\|/g, '\\|')} | ${b.label.replace(/\|/g, '\\|')} | ${b.member_count} |\n`
    }

    return md
  }

  generateKeywordReport(sessionId: string): string {
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

    let md = '# 关键词报告\n\n'
    md += '## 人脸关键词\n\n'
    if (keywordSet.size === 0) {
      md += '*(无)*\n'
    } else {
      for (const k of Array.from(keywordSet).sort()) {
        md += `- ${k}\n`
      }
    }

    md += '\n## 筛选关键词\n\n'
    if (cullingKeywords.size === 0) {
      md += '*(无)*\n'
    } else {
      for (const k of Array.from(cullingKeywords).sort()) {
        md += `- ${k}\n`
      }
    }

    return md
  }
}
