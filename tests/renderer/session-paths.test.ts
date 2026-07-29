import { describe, expect, it } from 'vitest'
import {
  getCommonParentPath,
  getPathBasename,
} from '../../desktop/src/renderer/pages/Dashboard'

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
})
