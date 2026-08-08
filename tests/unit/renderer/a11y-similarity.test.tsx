import React from 'react'
import { render, screen } from '@testing-library/react'
import { axe, toHaveNoViolations } from 'jest-axe'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import Similarity from '../../../desktop/src/renderer/pages/Similarity/index'

expect.extend(toHaveNoViolations)

vi.mock('react-router-dom', () => ({
  useParams: () => ({ sessionId: 'session-a' }),
}))

vi.mock('@tanstack/react-query', () => {
  const result = {
    groups: [
      {
        id: 1,
        label: 'group one',
        count: 3,
        images: [
          { path: '/photos/a.jpg', representative: true },
          { path: '/photos/b.jpg' },
          { path: '/photos/c.jpg' },
        ],
      },
      {
        id: 2,
        label: 'group two',
        count: 1,
        images: [{ path: '/photos/d.jpg', representative: true }],
      },
    ],
    ungrouped: [],
    stats: { totalGroups: 2, totalUngrouped: 0, threshold: 10, minGroupSize: 2, groupingMode: 'global' },
  }
  return {
    useQuery: () => ({ data: result, isLoading: false, error: null }),
    useMutation: () => ({ mutate: vi.fn(), isPending: false, isError: false, error: null }),
    useQueryClient: () => ({ invalidateQueries: vi.fn(), setQueryData: vi.fn() }),
  }
})

vi.mock('../../../desktop/src/renderer/api/similarity', () => ({
  similarityApi: {
    getResult: vi.fn(),
    analyze: vi.fn(),
    cancel: vi.fn(),
    recluster: vi.fn(),
    previewWriteback: vi.fn(),
    writeback: vi.fn(),
    retryFailedWriteback: vi.fn(),
    confirmSync: vi.fn(),
    cleanup: vi.fn(),
  },
}))

vi.mock('../../../desktop/src/renderer/api/jobs', () => ({
  jobsApi: { list: vi.fn(async () => []) },
}))

vi.mock('../../../desktop/src/renderer/api/captureOne', () => ({
  captureOneApi: {
    health: vi.fn(),
    syncState: vi.fn(async () => ({
      state: 'connected',
      reloadAckedAt: null,
      xmp: { pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0 },
    })),
  },
}))

vi.mock('../../../desktop/src/renderer/hooks/useEvent', () => ({
  useEvent: () => undefined,
}))

vi.mock('../../../desktop/src/renderer/components/WritebackReport/WritebackReport', () => ({
  __esModule: true,
  default: () => null,
}))

beforeEach(() => {
  document.documentElement.lang = 'zh-CN'
  document.title = 'a11y-similarity'
})

describe('Similarity group header axe scans', () => {
  it('renders the group header region without axe violations', async () => {
    render(
      <main>
        <Similarity />
      </main>,
    )
    // Await the async mount effects (syncState refresh) inside act.
    const expandButtons = (await screen.findAllByRole('button')).filter(
      (button) => button.hasAttribute('aria-expanded'),
    )
    expect(expandButtons).toHaveLength(2)
    const groupCard = expandButtons[0].closest('div')?.parentElement
    expect(groupCard).not.toBeNull()
    expect(await axe(groupCard as HTMLElement)).toHaveNoViolations()
  })

  it('scans the full page with no axe violations (F-2 sliders label-associated, F-3 keyword input labeled)', async () => {
    render(
      <main>
        <Similarity />
      </main>,
    )
    await screen.findAllByRole('button')
    // F-2 regression: both range sliders must be label-associated (id +
    // label[for]) — structural query, no copy dependency.
    const ranges = document.querySelectorAll<HTMLInputElement>('input[type="range"]')
    expect(ranges).toHaveLength(2)
    for (const range of Array.from(ranges)) {
      const rangeId = range.getAttribute('id')
      expect(rangeId).toBeTruthy()
      expect(document.querySelector(`label[for="${rangeId}"]`)).not.toBeNull()
    }
    const results = await axe(document.body)
    const ids = results.violations.map((violation) => violation.id)
    // The two range sliders are label-associated now, so no label-rule
    // findings remain; the placeholder-only keyword input is labeled via
    // aria-label (F-3, axe's label rule false-negative on placeholders
    // no longer applies). A clean scan pins []: any new violation fails.
    expect(ids).toEqual([])
  })
})
