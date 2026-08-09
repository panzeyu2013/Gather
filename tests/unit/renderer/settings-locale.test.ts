import { describe, expect, it, vi } from 'vitest'
import { resetSettingsAndApplyLocale } from '../../../desktop/src/renderer/utils/settings-locale'

describe('resetSettingsAndApplyLocale', () => {
  it('applies the effective locale returned after settings reset', async () => {
    const calls: string[] = []
    const reset = vi.fn(async () => { calls.push('reset') })
    const getLocale = vi.fn(async () => {
      calls.push('get-locale')
      return { language: 'zh-CN' as const }
    })
    const applyLocale = vi.fn(async (language: 'zh-CN' | 'en') => {
      calls.push(`apply-${language}`)
    })

    await expect(resetSettingsAndApplyLocale(reset, getLocale, applyLocale))
      .resolves.toBe('zh-CN')
    expect(calls).toEqual(['reset', 'get-locale', 'apply-zh-CN'])
  })

  it('does not change locale when resetting settings fails', async () => {
    const getLocale = vi.fn(async () => ({ language: 'en' as const }))
    const applyLocale = vi.fn(async () => undefined)

    await expect(resetSettingsAndApplyLocale(
      async () => { throw new Error('reset failed') },
      getLocale,
      applyLocale,
    )).rejects.toThrow('reset failed')
    expect(getLocale).not.toHaveBeenCalled()
    expect(applyLocale).not.toHaveBeenCalled()
  })
})
