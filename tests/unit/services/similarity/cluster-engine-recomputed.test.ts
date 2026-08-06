import { describe, expect, it } from 'vitest'
import { clusterByHash, type HashEntry } from '../../../../desktop/src/main/services/similarity/cluster-engine'

function popcount(value: bigint): number {
  let count = 0
  let v = value
  while (v !== 0n) {
    v &= v - 1n
    count++
  }
  return count
}

function xorBits(hex: string, bits: number[]): string {
  let value = BigInt(`0x${hex}`)
  for (const bit of bits) value ^= 1n << BigInt(bit)
  return value.toString(16).padStart(16, '0')
}

function sortedMemberSets(result: { groups: string[][] }): string[] {
  return result.groups.map(group => [...group].sort().join(',')).sort()
}

// Regression test for the recomputed-path (n > 32768) grouping divergence.
// The wave-BFS path adopts every node that reaches its frontier, while the old
// recomputed expansion skipped neighbors that a prior seed check had marked
// visited-but-ungrouped. Same input then grouped differently on either side
// of the 32768 boundary.
describe('clusterByHash recomputed path (n > 32768) parity', () => {
  it('adopts a sparse node that precedes a dense component on both paths', () => {
    // Graph: s — d2 — {d1, d3}, with s (index 0) having exactly one neighbor
    // (d2) and a region below minGroupSize=3. The old recomputed path marked s
    // visited-and-ungrouped before the dense component ran, so d2's expansion
    // never queued it and s was dropped from the group; wave BFS adopted it.
    const d1 = '0000000000000000'
    const d2 = '000000000000000f'
    const d3 = '00000000000000f0'
    // s = d2 xor 28 set bits at positions 8..35: 32 bits set in total, so it
    // sits within threshold of d2 only (d1/d3 distance 32, both > 30).
    const s = xorBits(d2, Array.from({ length: 28 }, (_, i) => 8 + i))
    const filler = 'ffffffffffffffff'

    expect(popcount(BigInt(`0x${s}`) ^ BigInt(`0x${d2}`))).toBe(28)
    expect(popcount(BigInt(`0x${s}`) ^ BigInt(`0x${d1}`))).toBe(32)
    expect(popcount(BigInt(`0x${s}`) ^ BigInt(`0x${d3}`))).toBe(36)
    expect(popcount(BigInt(`0x${filler}`) ^ BigInt(`0x${s}`))).toBe(32)

    // ~40 hashes: sparse node first, then the dense component, then a blob of
    // identical fillers that form their own group.
    const entries: HashEntry[] = [
      { photoId: 's', hash: s },
      { photoId: 'd1', hash: d1 },
      { photoId: 'd2', hash: d2 },
      { photoId: 'd3', hash: d3 },
      ...Array.from({ length: 36 }, (_, index) => ({
        photoId: `f${index}`,
        hash: filler,
      })),
    ]
    expect(entries).toHaveLength(40)

    const threshold = 30
    const minGroupSize = 3
    // Default dispatch uses the bitset/wave-BFS path for 40 entries; the
    // exported maxBitsetEntries hook forces the recomputed path.
    const wavePath = clusterByHash(entries, threshold, minGroupSize, 'global')
    const recomputedPath = clusterByHash(entries, threshold, minGroupSize, 'global', undefined, 0)

    expect(sortedMemberSets(recomputedPath)).toEqual(sortedMemberSets(wavePath))
    expect(recomputedPath.ungrouped.sort()).toEqual(wavePath.ungrouped.sort())

    // Pure graph semantics: the sparse node that precedes the dense seed still
    // joins the group on both paths.
    for (const result of [wavePath, recomputedPath]) {
      const sparseGroup = result.groups.find(group => group.includes('s'))
      expect(sparseGroup, 'sparse node must be adopted').toBeDefined()
      expect(sparseGroup!.sort()).toEqual(['d1', 'd2', 'd3', 's'])
      expect(result.ungrouped).toEqual([])
    }
  })

  it('emits the final progress value on both paths', () => {
    const entries: HashEntry[] = [
      { photoId: 'a', hash: '0000000000000000' },
      { photoId: 'b', hash: '0000000000000001' },
      { photoId: 'c', hash: '0000000000000003' },
    ]
    const progress: Array<[number, number]> = []
    clusterByHash(entries, 2, 2, 'global', (current, total) => progress.push([current, total]))
    expect(progress[progress.length - 1]).toEqual([3, 3])

    progress.length = 0
    clusterByHash(entries, 2, 2, 'global', (current, total) => progress.push([current, total]), 0)
    // The recomputed path reports against 2n (region pass + clustering pass).
    expect(progress[progress.length - 1]).toEqual([6, 6])
  })
})
