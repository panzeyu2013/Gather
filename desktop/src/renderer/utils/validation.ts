export function isValidBase64(s: string): boolean {
  if (!s || /\s/.test(s)) return false
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(s)) return false
  if (s.length % 4 === 1) return false
  return true
}

export function clampInteger(value: string | number, fallback: number, min: number, max: number): number {
  const parsed = typeof value === 'number' ? value : Number.parseInt(value, 10)
  if (!Number.isFinite(parsed)) return fallback
  return Math.min(max, Math.max(min, parsed))
}
