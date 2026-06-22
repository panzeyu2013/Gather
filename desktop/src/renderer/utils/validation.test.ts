import { clampInteger, isValidBase64 } from './validation'

describe('isValidBase64', () => {
  it('accepts a valid base64 string without padding', () => {
    expect(isValidBase64('SGVsbG9Xb3JsZA')).toBe(true)
  })

  it('accepts a valid base64 string with == padding', () => {
    expect(isValidBase64('SGVsbG8=')).toBe(true)
  })

  it('accepts a valid base64 string with = padding', () => {
    expect(isValidBase64('YWJjZA')).toBe(true)
  })

  it('accepts a string containing only + and / characters', () => {
    expect(isValidBase64('+/+/+/')).toBe(true)
  })

  it('accepts URL-safe base64 with - and _', () => {
    expect(isValidBase64('SGVsbG8tV29ybGQ')).toBe(true)
    expect(isValidBase64('SGVsbG9fV29ybGQ')).toBe(true)
  })

  it('returns false for an empty string', () => {
    expect(isValidBase64('')).toBe(false)
  })

  it('returns false for a whitespace-only string', () => {
    expect(isValidBase64('   ')).toBe(false)
  })

  it('returns false for strings with invalid characters', () => {
    expect(isValidBase64('abc!@#')).toBe(false)
    expect(isValidBase64('hello world')).toBe(false)
    expect(isValidBase64('abc\n123')).toBe(false)
  })

  it('returns false for data URI prefix strings (contains invalid chars like :, ;, ,)', () => {
    expect(isValidBase64('data:image/png;base64,SGVsbG9Xb3JsZA')).toBe(false)
  })

  it('rejects invalid padding', () => {
    expect(isValidBase64('====')).toBe(false)
    expect(isValidBase64('SGV=sbG8')).toBe(false)
    expect(isValidBase64('SGVsbG8===')).toBe(false)
    expect(isValidBase64('abcde')).toBe(false)
  })

  it('handles edge case: mixed case alphanumeric with +/', () => {
    expect(isValidBase64('AbC123+/')).toBe(true)
  })
})

describe('clampInteger', () => {
  it('returns parsed integers inside the allowed range', () => {
    expect(clampInteger('12', 8, 1, 20)).toBe(12)
    expect(clampInteger(7, 8, 1, 20)).toBe(7)
  })

  it('falls back for empty or non-numeric values', () => {
    expect(clampInteger('', 8, 1, 20)).toBe(8)
    expect(clampInteger('abc', 8, 1, 20)).toBe(8)
  })

  it('clamps values outside the allowed range', () => {
    expect(clampInteger('0', 8, 1, 20)).toBe(1)
    expect(clampInteger('42', 8, 1, 20)).toBe(20)
  })
})
