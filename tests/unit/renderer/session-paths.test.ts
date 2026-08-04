import { describe, expect, it } from 'vitest'
import {
  getCommonParentPath,
  getPathBasename,
} from '../../../desktop/src/renderer/pages/Dashboard'
import {
  commonParentDirectory,
  normalizeImportFilepaths,
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
})
