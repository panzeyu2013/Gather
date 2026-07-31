export interface DatabaseRuntimeSettings {
  synchronous: 'OFF' | 'NORMAL' | 'FULL' | 'EXTRA'
  cacheSizeMb: number
}

export function normalizeDatabaseRuntimeSettings(
  synchronousValue: string,
  cacheSizeValue: number,
): DatabaseRuntimeSettings {
  const candidate = synchronousValue.trim().toUpperCase()
  const synchronous = (
    ['OFF', 'NORMAL', 'FULL', 'EXTRA'] as const
  ).find(value => value === candidate) ?? 'NORMAL'
  const cacheSizeMb = Number.isFinite(cacheSizeValue)
    ? Math.min(4096, Math.max(1, Math.floor(cacheSizeValue)))
    : 64
  return { synchronous, cacheSizeMb }
}
