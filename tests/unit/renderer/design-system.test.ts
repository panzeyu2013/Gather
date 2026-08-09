import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const root = resolve(__dirname, '../../..')

function source(path: string): string {
  return readFileSync(resolve(root, path), 'utf8')
}

describe('renderer control style baseline', () => {
  it('keeps the shared control geometry and visible keyboard focus treatment', () => {
    const css = source('desktop/src/renderer/styles/global.css')

    expect(css).toContain('--radius-control: 12px')
    expect(css).toContain('--control-height-md: 40px')
    expect(css).toContain('--color-control-border: #958c82')
    expect(css).toContain(':focus-visible')
    expect(css).toContain('outline: 2px solid color-mix(in srgb, var(--color-primary) 80%, white) !important')
  })

  it('wraps the culling toolbar before desktop controls overflow', () => {
    const css = source('desktop/src/renderer/pages/SessionDetail/Culling.module.css')
    const responsiveRule = css.match(/@media \(max-width: 1400px\) \{[\s\S]*?\n\}/)?.[0]

    expect(responsiveRule).toBeTruthy()
    expect(responsiveRule).toContain('flex-wrap: wrap')
  })

  it('keeps primary dashboard actions vertically centered on the shared height', () => {
    const css = source('desktop/src/renderer/pages/Dashboard/Dashboard.module.css')

    expect(css).toMatch(/\.newBtn[\s\S]*?display: inline-flex/)
    expect(css).toMatch(/\.newBtn[\s\S]*?min-height: var\(--control-height-md\)/)
    expect(css).toMatch(/\.newBtn[\s\S]*?align-items: center/)
    expect(css).toMatch(/\.newBtn[\s\S]*?min-width: 112px/)
    expect(css).toMatch(/\.multiSelectBtn[\s\S]*?min-width: 112px/)
    expect(css).toMatch(/\.multiSelectBtn[\s\S]*?min-height: var\(--control-height-md\)/)
  })

  it('keeps the library workspace switcher compact and aligned with the title', () => {
    const css = source('desktop/src/renderer/pages/Library/Library.module.css')
    const page = source('desktop/src/renderer/pages/Library/index.tsx')

    expect(page).toContain('className={styles.workspaceSelectWrap}')
    expect(page).toContain('className={styles.workspaceSelectIcon}')
    expect(css).toMatch(/\.workspaceSelect[\s\S]*?min-height: var\(--control-height-sm\)/)
    expect(css).toMatch(/\.workspaceSelectWrap[\s\S]*?margin-top: 18px/)
    expect(css).toMatch(/\.workspaceSelect[\s\S]*?border-radius: 8px/)
    expect(css).toMatch(/\.workspaceSelect[\s\S]*?padding: 0 34px 0 10px/)
    expect(css).toMatch(/\.workspaceSelectIcon[\s\S]*?right: 10px/)
    expect(css).toMatch(/@media \(max-width: 760px\)[\s\S]*?\.workspaceSelect[\s\S]*?min-height: var\(--control-height-md\)/)
  })

  it('balances library filter select spacing and separates the clear action', () => {
    const css = source('desktop/src/renderer/pages/Library/Library.module.css')
    const page = source('desktop/src/renderer/pages/Library/index.tsx')

    expect(page).toContain('className={styles.filterSelectWrap}')
    expect(page).toContain('className={styles.filterSelectIcon}')
    expect(page).toContain('className={styles.filterActions}')
    expect(page).toContain('className={styles.advancedFilters}')
    expect(page).toContain('className={styles.moreFiltersBtn}')
    expect(page).toContain('className={styles.clearFiltersBtn}')
    expect(css).toMatch(/\.filterSelect[\s\S]*?appearance: none[\s\S]*?padding: 0 34px 0 12px/)
    expect(css).toMatch(/\.filterSelectIcon[\s\S]*?right: 12px/)
    expect(css).toMatch(/\.filterActions[\s\S]*?justify-content: space-between/)
    expect(css).toMatch(/\.clearFiltersBtn[\s\S]*?min-height: 32px/)
  })

  it('keeps advanced analysis controls behind user-friendly presets', () => {
    const similarity = source('desktop/src/renderer/pages/Similarity/index.tsx')
    const face = source('desktop/src/renderer/pages/FaceKeywording/StepAnalyze.tsx')
    const duplicates = source('desktop/src/renderer/pages/SessionDetail/Duplicates.tsx')

    for (const page of [similarity, face, duplicates]) {
      expect(page).toContain("t('analysisPreset.label')")
      expect(page).toContain("t('analysisPreset.advanced')")
      expect(page).toContain('<details')
      expect(page).toContain('aria-pressed={activePreset === preset}')
    }

    for (const path of [
      'desktop/src/renderer/pages/Similarity/Similarity.module.css',
      'desktop/src/renderer/pages/FaceKeywording/StepAnalyze.module.css',
      'desktop/src/renderer/pages/SessionDetail/Duplicates.module.css',
    ]) {
      const css = source(path)
      const activeRule = css.match(/\.presetActive\s*\{[^}]*\}/)?.[0] ?? ''
      expect(activeRule).not.toContain('box-shadow')
    }
  })

  it('keeps export actions visible above the long settings form', () => {
    const page = source('desktop/src/renderer/pages/SessionDetail/Export.tsx')
    const css = source('desktop/src/renderer/pages/SessionDetail/Export.module.css')

    expect(page.indexOf('className={styles.actionBar}')).toBeLessThan(page.indexOf('className={styles.formGrid}'))
    expect(css).toMatch(/\.actionBar[\s\S]*?position: sticky/)
    expect(css).toMatch(/\.actionBar[\s\S]*?z-index: 12/)
  })

  it('does not simulate selected navigation with a dark inset shadow', () => {
    const sessionCss = source('desktop/src/renderer/pages/SessionDetail/SessionDetail.module.css')
    const cullingCss = source('desktop/src/renderer/pages/SessionDetail/Culling.module.css')

    expect(sessionCss).not.toContain('box-shadow: inset 0 -2px')
    expect(cullingCss).not.toContain('box-shadow: inset 0 -2px')
  })

  it('collapses completed jobs and avoids nested interactive dashboard cards', () => {
    const jobs = source('desktop/src/renderer/pages/Jobs/index.tsx')
    const dashboard = source('desktop/src/renderer/pages/Dashboard/index.tsx')

    expect(jobs).toContain('aria-expanded={showHistory}')
    expect(jobs).toContain('renderJob(job, true)')
    expect(dashboard).toContain('className={styles.cardOpen}')
    expect(dashboard).not.toContain("role={selectMode ? 'checkbox' : 'link'}")
  })
})
