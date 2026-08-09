import { describe, expect, it } from 'vitest'
import { mainCopy } from '../../../desktop/src/main/locale-copy'

// Main-side copy tables (menu / ML backend / fatal dialog / report templates)
// are the only surfaces the renderer cannot own; both locales must be fully
// populated with no stray English/zh defaults in the wrong table.
describe('mainCopy — 主进程统一文案表', () => {
  it('provides every table for both locales', () => {
    for (const locale of ['zh-CN', 'en'] as const) {
      const copy = mainCopy(locale)
      expect(Object.keys(copy.menu).length).toBeGreaterThan(10)
      expect(copy.mlBackendAuto.length).toBeGreaterThan(0)
      expect(copy.fatalDialog.title.length).toBeGreaterThan(0)
      for (const report of Object.values(copy.reports)) {
        expect(Object.values(report).every((v) => typeof v === 'string' && v.length > 0)).toBe(true)
      }
    }
  })

  it('keeps the renderer-owned language untouched: zh menu ≠ en menu, reports differ', () => {
    const zh = mainCopy('zh-CN')
    const en = mainCopy('en')
    expect(zh.menu.file).toBe('文件')
    expect(en.menu.file).toBe('File')
    expect(zh.reports.sessionSummary.title).not.toBe(en.reports.sessionSummary.title)
    expect(zh.fatalDialog.title).toBe('Gather 无法启动')
    expect(en.fatalDialog.title).toBe('Gather failed to start')
  })

  it('fatal dialog body interpolates the raw diagnostic', () => {
    const body = mainCopy('zh-CN').fatalDialog.body('boom')
    expect(body).toContain('boom')
  })
})
