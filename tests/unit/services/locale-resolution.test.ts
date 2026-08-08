import { describe, expect, it } from 'vitest'
import {
  isAppLocale,
  resolveAppLocale,
  resolveEffectiveLocale,
} from '../../../desktop/src/main/locale'

describe('resolveAppLocale (--lang / system locale)', () => {
  it('prefers the --lang switch over the system locale', () => {
    expect(resolveAppLocale('zh-CN', 'en-US')).toBe('zh-CN')
    expect(resolveAppLocale('en-US', 'zh-CN')).toBe('en')
  })

  it('maps any zh-prefixed value to zh-CN (case-insensitive)', () => {
    expect(resolveAppLocale('', 'zh-Hans-CN')).toBe('zh-CN')
    expect(resolveAppLocale('', 'ZH-TW')).toBe('zh-CN')
  })

  it('falls back to en for everything not zh-prefixed', () => {
    expect(resolveAppLocale('', 'fr-FR')).toBe('en')
    expect(resolveAppLocale('', '')).toBe('en')
    expect(resolveAppLocale('', 'de-DE')).toBe('en')
  })
})

describe('resolveEffectiveLocale (settings override > --lang > system > en)', () => {
  it('gives the ui_language setting override top priority', () => {
    expect(resolveEffectiveLocale('en-US', 'en-US', 'zh-CN')).toBe('zh-CN')
    expect(resolveEffectiveLocale('zh-CN', 'zh-CN', 'en')).toBe('en')
  })

  it('falls back to the --lang switch when the override is unset', () => {
    expect(resolveEffectiveLocale('zh-CN', 'en-US', '')).toBe('zh-CN')
    expect(resolveEffectiveLocale('en-US', 'zh-CN', '')).toBe('en')
  })

  it('falls back to the system locale when neither override nor switch is set', () => {
    expect(resolveEffectiveLocale('', 'zh-Hans-CN', '')).toBe('zh-CN')
    expect(resolveEffectiveLocale('', 'fr-FR', '')).toBe('en')
  })

  it('treats an invalid override as unset (does not poison the chain)', () => {
    expect(resolveEffectiveLocale('zh-CN', 'en-US', 'fr')).toBe('zh-CN')
    expect(resolveEffectiveLocale('', 'en-US', 'xx-yy')).toBe('en')
  })

  it('falls back to en when nothing is set', () => {
    expect(resolveEffectiveLocale('', '', '')).toBe('en')
  })
})

describe('isAppLocale', () => {
  it('accepts only the two supported locales', () => {
    expect(isAppLocale('zh-CN')).toBe(true)
    expect(isAppLocale('en')).toBe(true)
    expect(isAppLocale('fr')).toBe(false)
    expect(isAppLocale('zh-cn')).toBe(false)
    expect(isAppLocale(undefined)).toBe(false)
    expect(isAppLocale(42)).toBe(false)
  })
})
