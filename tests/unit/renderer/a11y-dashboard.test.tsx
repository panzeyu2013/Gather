import React from 'react'
import { fireEvent, render, waitFor } from '@testing-library/react'
import { axe, toHaveNoViolations } from 'jest-axe'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import Dashboard from '../../../desktop/src/renderer/pages/Dashboard/index'

expect.extend(toHaveNoViolations)

vi.mock('react-router-dom', () => ({
  useNavigate: () => vi.fn(),
}))

vi.mock('@tanstack/react-query', () => {
  const session = {
    id: 's-1',
    name: 'workspace one',
    status: 'draft',
    photoCount: 42,
    analysisStatus: 'pending',
    writebackStatus: 'none',
    importSource: 'local',
    sourcePath: '/photos',
    failedWritebackCount: 0,
    truncatedImport: false,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
  }
  return {
    useQuery: () => ({ data: [session], isLoading: false, error: null }),
    useMutation: () => ({ mutate: vi.fn(), isPending: false, isError: false, error: null }),
    useQueryClient: () => ({ invalidateQueries: vi.fn() }),
  }
})

vi.mock('../../../desktop/src/renderer/api/session', () => ({
  sessionApi: {
    list: vi.fn(),
    create: vi.fn(),
    createFromDirectory: vi.fn(),
    delete: vi.fn(),
    deleteMany: vi.fn(),
    addPhotos: vi.fn(),
  },
}))

vi.mock('../../../desktop/src/renderer/api/jobs', () => ({
  jobsApi: { list: vi.fn(async () => []) },
}))

vi.mock('../../../desktop/src/renderer/hooks/useEvent', () => ({
  useEvent: () => undefined,
}))

beforeEach(() => {
  document.documentElement.lang = 'zh-CN'
  document.title = 'a11y-dashboard'
  ;(window as unknown as { gather: unknown }).gather = {
    sendCommand: vi.fn(),
    onEvent: vi.fn(() => () => undefined),
    selectDirectory: vi.fn(async () => '/photos/one'),
    getSelectedPhotos: vi.fn(async () => ['/photos/one/a.jpg']),
    getC1Health: vi.fn(async () => ({
      reachable: true,
      appRunning: true,
      appName: 'Capture One',
      documentOpen: true,
      automationAuthorized: true,
      selectedCount: 2,
      latencyMs: 12,
      lastError: null,
      timestamp: '2026-01-01T00:00:00.000Z',
    })),
    reloadMetadata: vi.fn(async () => undefined),
  }
})

describe('Dashboard create-session dialog axe scans', () => {
  it('opens the create dialog and reports no axe violations (F-1 select now label-associated)', async () => {
    const { container } = render(
      <main>
        <Dashboard />
      </main>,
    )
    const newButton = container.querySelector<HTMLButtonElement>('[class*="newBtn"]')
    expect(newButton).not.toBeNull()
    fireEvent.click(newButton!)

    await waitFor(() => {
      expect(document.querySelector('[role="dialog"]')).not.toBeNull()
    })
    // F-1 regression: the import-source <select> must have a programmatic
    // label (id + label[for]) — structural query, no copy dependency.
    const sourceSelect = document.querySelector<HTMLSelectElement>('select')
    expect(sourceSelect).not.toBeNull()
    const selectId = sourceSelect!.getAttribute('id')
    expect(selectId).toBeTruthy()
    expect(document.querySelector(`label[for="${selectId}"]`)).not.toBeNull()
    // The dialog scan must be clean: the name/folder inputs and the select
    // are all label-associated now (F-1/F-3), so no pinned finding set.
    const dialog = document.querySelector('[role="dialog"]')
    expect(dialog).not.toBeNull()
    const results = await axe(dialog as HTMLElement)
    const ids = results.violations.map((violation) => violation.id)
    expect(ids).toEqual([])
  })

  it('renders the Capture One preflight block (c1:health passed) with no violations, and the dialog scan is clean', async () => {
    const { container } = render(
      <main>
        <Dashboard />
      </main>,
    )
    const newButton = container.querySelector<HTMLButtonElement>('[class*="newBtn"]')
    expect(newButton).not.toBeNull()
    fireEvent.click(newButton!)

    // Switch the import source to Capture One; the preflight effect fires
    // window.gather.getC1Health and renders the four check rows.
    const sourceSelect = document.querySelector<HTMLSelectElement>('select')
    expect(sourceSelect).not.toBeNull()
    fireEvent.change(sourceSelect!, { target: { value: 'capture-one' } })

    await waitFor(() => {
      expect(document.querySelectorAll('[class*="c1CheckList"] > div')).toHaveLength(4)
    })
    const preflight = document.querySelector('[aria-live="polite"]')
    expect(preflight).not.toBeNull()
    expect(await axe(preflight as HTMLElement)).toHaveNoViolations()

    const dialog = document.querySelector('[role="dialog"]')
    const results = await axe(dialog as HTMLElement)
    const ids = results.violations.map((violation) => violation.id)
    expect(ids).toEqual([])
  })
})
