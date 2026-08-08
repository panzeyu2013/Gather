import React from 'react'
import { render } from '@testing-library/react'
import { axe, toHaveNoViolations } from 'jest-axe'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import Dialog from '../../../desktop/src/renderer/components/Dialog/Dialog'

expect.extend(toHaveNoViolations)

// jest-axe scans the whole document by default; give jsdom a well-formed
// document so environment-only rules (html-has-lang, document-title) stay quiet.
beforeEach(() => {
  document.documentElement.lang = 'zh-CN'
  document.title = 'a11y-dialog'
})

afterEach(() => {
  document.querySelector('main')?.removeAttribute('inert')
})

describe('Dialog axe scans', () => {
  it('has no axe violations when open with focusable content', async () => {
    render(
      <main>
        <Dialog open onClose={() => {}} title="dialog title">
          <button type="button">option a</button>
          <button type="button">option b</button>
        </Dialog>
      </main>,
    )
    const dialog = document.querySelector('[role="dialog"]')
    expect(dialog).not.toBeNull()
    expect(await axe(dialog as HTMLElement)).toHaveNoViolations()
  })

  it('has no axe violations in the zero-focusables edge (text-only body)', async () => {
    render(
      <main>
        <Dialog open onClose={() => {}} title="dialog title">
          <p>text only content</p>
        </Dialog>
      </main>,
    )
    const dialog = document.querySelector('[role="dialog"]')
    expect(dialog).not.toBeNull()
    expect(await axe(dialog as HTMLElement)).toHaveNoViolations()
  })

  it('has no axe violations after the dialog closes (unmounted state)', async () => {
    const { rerender, container } = render(
      <main>
        <Dialog open onClose={() => {}} title="dialog title">
          <button type="button">option a</button>
        </Dialog>
      </main>,
    )
    rerender(
      <main>
        <Dialog open={false} onClose={() => {}} title="dialog title">
          <button type="button">option a</button>
        </Dialog>
      </main>,
    )
    expect(document.querySelector('[role="dialog"]')).toBeNull()
    expect(await axe(container as HTMLElement)).toHaveNoViolations()
  })
})

describe('axe matcher sanity', () => {
  it('reports a label violation for an unnamed control, proving the matcher detects failures', async () => {
    const { container } = render(
      <main>
        <input type="checkbox" />
      </main>,
    )
    const results = await axe(container as HTMLElement)
    const ids = results.violations.map((violation) => violation.id)
    expect(ids).toContain('label')
  })
})
