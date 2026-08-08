import { describe, expect, it } from 'vitest'
import {
  clusterByHash,
  clusterByHashMulti,
  type HashEntry,
} from '../../../../desktop/src/main/services/similarity/cluster-engine'

const emptyResult = (): { groups: string[][]; ungrouped: string[] } => ({
  groups: [],
  ungrouped: [],
})

function makeEntries(count: number): HashEntry[] {
  const entries: HashEntry[] = []
  for (let i = 0; i < count; i++) {
    entries.push({ photoId: `p${i}`, hash: i.toString(16).padStart(16, '0') })
  }
  return entries
}

function sortGroups(result: { groups: string[][]; ungrouped: string[] }): {
  groups: string[][]
  ungrouped: string[]
} {
  return {
    groups: result.groups
      .map(group => [...group].sort())
      .sort((a, b) => a[0].localeCompare(b[0])),
    ungrouped: [...result.ungrouped].sort(),
  }
}

describe('clusterByHashMulti', () => {
  it('matches per-threshold clusterByHash results on the recomputed (large) path', () => {
    // A single distance pass must produce exactly the same groups and
    // ungrouped sets as clustering each threshold independently. The test
    // hook forces the recomputed path on a small input; sequential hashes
    // give it a dense cluster structure to chew on.
    const entries = makeEntries(600)
    const thresholds = [2, 6, 14, 18]
    const multi = clusterByHashMulti(entries, thresholds, 2, 'global', undefined, 64)
    for (const [index, tier] of thresholds.entries()) {
      const single = clusterByHash(entries, tier, 2, 'global', undefined, 64)
      expect(sortGroups(multi[index])).toEqual(sortGroups(single))
    }
  })

  it('matches per-threshold results on the bitset path', () => {
    const entries = makeEntries(2000)
    const thresholds = [4, 8, 12]
    const multi = clusterByHashMulti(entries, thresholds, 2, 'global')
    for (const [index, tier] of thresholds.entries()) {
      const single = clusterByHash(entries, tier, 2, 'global')
      expect(sortGroups(multi[index])).toEqual(sortGroups(single))
    }
  })

  it('supports sequential mode and duplicate thresholds', () => {
    const entries = makeEntries(64)
    const multi = clusterByHashMulti(entries, [6, 6, 10], 2, 'sequential')
    expect(multi).toHaveLength(3)
    expect(multi[0]).toEqual(multi[1])
    expect(sortGroups(multi[2])).toEqual(
      sortGroups(clusterByHash(entries, 10, 2, 'sequential')),
    )
  })

  it('returns empty results for empty inputs', () => {
    const multi = clusterByHashMulti([], [2, 6], 2, 'global')
    expect(multi).toEqual([emptyResult(), emptyResult()])
  })

  it('emits monotonic progress across the shared pass and every tier', () => {
    const entries = makeEntries(100)
    const seen: number[] = []
    clusterByHashMulti(entries, [4, 8], 2, 'global', (current) => {
      seen.push(current)
    })
    expect(seen.length).toBeGreaterThan(0)
    for (let i = 1; i < seen.length; i++) {
      expect(seen[i]).toBeGreaterThanOrEqual(seen[i - 1])
    }
    expect(seen[seen.length - 1]).toBeLessThanOrEqual(100 * 3)
  })
})
