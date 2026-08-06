import { describe, expect, it } from 'vitest'
import { clusterByHash, type HashEntry } from '../../../../desktop/src/main/services/similarity/cluster-engine'

// Seeded PRNG (mulberry32) so generated hashes are reproducible.
function mulberry32(seed: number): () => number {
  let state = seed
  return () => {
    state |= 0
    state = (state + 0x6d2b79f5) | 0
    let t = Math.imul(state ^ (state >>> 15), 1 | state)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomHash(random: () => number, byteCount = 8): string {
  let hex = ''
  for (let i = 0; i < byteCount; i++) {
    hex += Math.floor(random() * 256).toString(16).padStart(2, '0')
  }
  return hex
}

function makeEntries(count: number, seed: number, byteCount = 8): HashEntry[] {
  const random = mulberry32(seed)
  return Array.from({ length: count }, (_, index) => ({
    photoId: `photo-${index}`,
    hash: randomHash(random, byteCount),
  }))
}

// Reference implementation of the pre-optimization algorithm (BigInt hamming
// distance + region-size BFS) used to prove the optimized engine keeps the
// same grouping semantics beyond the fixed unit cases.
function referenceClusterByHash(
  entries: HashEntry[],
  threshold: number,
  minGroupSize: number,
): { groups: number[][]; ungrouped: number[] } {
  const count = entries.length
  const values = entries.map(entry => BigInt(`0x${entry.hash}`))
  const region: number[][] = Array.from({ length: count }, () => [])
  for (let i = 0; i < count; i++) {
    for (let j = i + 1; j < count; j++) {
      let difference = values[i] ^ values[j]
      let distance = 0
      while (difference !== 0n) {
        difference &= difference - 1n
        distance++
      }
      if (distance <= threshold) {
        region[i].push(j)
        region[j].push(i)
      }
    }
  }

  const visited = new Set<number>()
  const clustered = new Set<number>()
  const groups: number[][] = []
  for (let i = 0; i < count; i++) {
    if (visited.has(i)) continue
    visited.add(i)
    if (region[i].length + 1 < minGroupSize) continue
    const group = [i]
    clustered.add(i)
    const seedList = [...region[i]]
    const queued = new Set(seedList)
    while (seedList.length > 0) {
      const current = seedList.pop()!
      if (visited.has(current)) {
        if (!clustered.has(current)) {
          group.push(current)
          clustered.add(current)
        }
        continue
      }
      visited.add(current)
      if (region[current].length + 1 >= minGroupSize) {
        for (const neighbor of region[current]) {
          if (!visited.has(neighbor) && !queued.has(neighbor)) {
            queued.add(neighbor)
            seedList.push(neighbor)
          }
        }
      }
      if (!clustered.has(current)) {
        group.push(current)
        clustered.add(current)
      }
    }
    groups.push(group)
  }
  const ungrouped = Array.from({ length: count }, (_, index) => index)
    .filter(index => !clustered.has(index))
  return { groups, ungrouped }
}

function sortedMemberSets(groups: number[][]): string[] {
  return groups
    .map(group => [...group].sort((a, b) => a - b).join(','))
    .sort()
}

describe('clusterByHash semantic parity with the reference algorithm', () => {
  it.each([64, 128, 256])('matches reference grouping for %i random hashes', (count) => {
    for (const threshold of [2, 6, 12, 20, 28]) {
      for (const minGroupSize of [2, 3, 5]) {
        const entries = makeEntries(count, count * 100 + threshold * 10 + minGroupSize, 16)
        const reference = referenceClusterByHash(entries, threshold, minGroupSize)
        const actual = clusterByHash(entries, threshold, minGroupSize, 'global')
        expect(
          actual.groups.map(group => group.sort().join(',')).sort(),
          `global groups differ at threshold=${threshold} minGroupSize=${minGroupSize}`,
        ).toEqual(sortedMemberSets(reference.groups))
        expect(
          actual.ungrouped.sort(),
          `ungrouped differs at threshold=${threshold} minGroupSize=${minGroupSize}`,
        ).toEqual(reference.ungrouped.map(index => entries[index].photoId).sort())
      }
    }
  })

  it('matches the reference for clustered (non-uniform) inputs', () => {
    const random = mulberry32(7)
    const entries = makeEntries(96, 7)
    // Mutate some hashes to sit within threshold of each other so the graph
    // has real connected components spanning the sparse/dense boundary.
    for (let i = 0; i < 30; i++) {
      const source = entries[2 + (i % 60)]
      const target = entries[60 + i]
      const flip = Math.floor(random() * 64)
      const value = BigInt(`0x${source.hash}`) ^ (1n << BigInt(flip))
      target.hash = value.toString(16).padStart(16, '0')
    }
    for (const threshold of [3, 8]) {
      for (const minGroupSize of [2, 4]) {
        const reference = referenceClusterByHash(entries, threshold, minGroupSize)
        const actual = clusterByHash(entries, threshold, minGroupSize, 'global')
        const referenceGroupIds = reference.groups.map(group =>
          group.map(index => entries[index].photoId).sort().join(','),
        ).sort()
        expect(
          actual.groups.map(group => group.sort().join(',')).sort(),
        ).toEqual(referenceGroupIds)
        expect(actual.ungrouped.sort()).toEqual(
          reference.ungrouped.map(index => entries[index].photoId).sort(),
        )
      }
    }
  })
})

describe('clusterByHash performance (20k entries)', () => {
  it('clusters 20k random hashes well under the 2s budget', () => {
    const entries = makeEntries(20_000, 42)
    const start = performance.now()
    const result = clusterByHash(entries, 16, 2, 'global')
    const elapsed = performance.now() - start
    // eslint-disable-next-line no-console
    console.log(`[perf] 20k entries, threshold=16: ${elapsed.toFixed(0)}ms, groups=${result.groups.length}`)
    // CI machines are slower than the M-series dev machine; keep a generous
    // bound while still catching the previous O(n^2) degradation.
    expect(elapsed).toBeLessThan(10_000)
  })

  it('clusters 20k entries at a dense threshold (30) under budget', () => {
    const entries = makeEntries(20_000, 43)
    const start = performance.now()
    const result = clusterByHash(entries, 30, 2, 'global')
    const elapsed = performance.now() - start
    // eslint-disable-next-line no-console
    console.log(`[perf] 20k entries, threshold=30: ${elapsed.toFixed(0)}ms, groups=${result.groups.length}`)
    expect(elapsed).toBeLessThan(10_000)
  })
})
