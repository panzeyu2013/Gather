import { describe, expect, it } from 'vitest'
import { sanitizeCaptureOneAppName } from '../../../desktop/src/main/capture-one'

describe('sanitizeCaptureOneAppName', () => {
  it('accepts exact and edition-suffixed Capture One install names', () => {
    expect(sanitizeCaptureOneAppName('Capture One')).toBe('Capture One')
    expect(sanitizeCaptureOneAppName('Capture One Pro')).toBe('Capture One Pro')
    expect(sanitizeCaptureOneAppName('Capture One Express')).toBe('Capture One Express')
    expect(sanitizeCaptureOneAppName('Capture One 16')).toBe('Capture One 16')
    expect(sanitizeCaptureOneAppName('Capture One 16 Pro')).toBe('Capture One 16 Pro')
    expect(sanitizeCaptureOneAppName('  Capture One Pro  ')).toBe('Capture One Pro')
    expect(sanitizeCaptureOneAppName('capture one pro')).toBe('capture one pro')
  })

  it('rejects names that could break the osascript string or are unrelated', () => {
    expect(sanitizeCaptureOneAppName('Capture One"; rm -rf /')).toBeNull()
    expect(sanitizeCaptureOneAppName('Capture One\nMore')).toBeNull()
    expect(sanitizeCaptureOneAppName('Capture One; echo x')).toBeNull()
    expect(sanitizeCaptureOneAppName('Capture One\x00')).toBeNull()
    expect(sanitizeCaptureOneAppName('Photoshop')).toBeNull()
    expect(sanitizeCaptureOneAppName('')).toBeNull()
    expect(sanitizeCaptureOneAppName('Finder')).toBeNull()
  })
})
