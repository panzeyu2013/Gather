import { describe, expect, it, vi } from 'vitest'
import {
  getCommonParentPath,
  getPathBasename,
} from '../../../desktop/src/renderer/utils/session-paths'
import {
  commonParentDirectory,
  normalizeImportFilepaths,
  SessionService,
} from '../../../desktop/src/main/services/session/session.service'

describe('session path defaults', () => {
  it('uses the selected folder name as the default session name', () => {
    expect(getPathBasename('/Users/test/Photos/Wedding/')).toBe('Wedding')
    expect(getPathBasename('D:\\Photos\\Portraits')).toBe('Portraits')
  })

  it('finds the shared import directory for plugin-selected files', () => {
    expect(getCommonParentPath([
      '/Users/test/Photos/Wedding/001.CR3',
      '/Users/test/Photos/Wedding/002.CR3',
    ])).toBe('/Users/test/Photos/Wedding')
  })

  it('does not use a filesystem root for unrelated plugin-selected files', () => {
    expect(getCommonParentPath([
      '/Shoot-A/001.CR3',
      '/Shoot-B/002.CR3',
    ])).toBe('')
    expect(commonParentDirectory([
      '/Shoot-A/001.CR3',
      '/Shoot-B/002.CR3',
    ])).toBe('')
  })

  it('normalizes and deduplicates equivalent import paths', () => {
    expect(normalizeImportFilepaths([
      '/Users/test/Photos/Wedding/../Wedding/001.CR3',
      '/Users/test/Photos/Wedding/001.CR3',
      '  /Users/test/Photos/Wedding/002.CR3  ',
    ])).toEqual([
      '/Users/test/Photos/Wedding/001.CR3',
      '/Users/test/Photos/Wedding/002.CR3',
    ])
  })

  it('does not recover the first directory for a multi-directory selection', () => {
    const updateSourcePath = vi.fn()
    const service = new SessionService(
      {
        get: vi.fn(() => ({
          id: 'session',
          name: 'Multi directory',
          status: 'photos_loaded',
          analysis_status: 'idle',
          writeback_status: 'idle',
          import_source: 'capture-one',
          source_path: '',
          photo_count: 2,
          failed_writeback_count: 0,
          created_at: '',
          updated_at: '',
        })),
        updateSourcePath,
      } as never,
      {
        getBySession: vi.fn(() => [
          { filepath: '/Shoot-A/001.CR3' },
          { filepath: '/Shoot-B/002.CR3' },
        ]),
      } as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
    )

    expect(service.getSession('session')?.sourcePath).toBe('')
    expect(updateSourcePath).not.toHaveBeenCalled()
  })
})
