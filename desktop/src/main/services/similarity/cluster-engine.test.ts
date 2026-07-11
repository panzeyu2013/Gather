import { describe, it, expect } from 'vitest'
import { clusterByHash } from './cluster-engine'

describe('clusterByHash', () => {
  it('groups identical hashes together', () => {
    const entries = [
      { photoId: 'a', hash: 'ffffffffffffffff' },
      { photoId: 'b', hash: 'ffffffffffffffff' },
      { photoId: 'c', hash: 'fffffffffffffffe' },
    ]
    const result = clusterByHash(entries, 4, 2)
    // a and b are identical (distance 0), c is distance 1 from both (<= 4)
    expect(result.groups).toHaveLength(1)
    expect(result.groups[0]).toHaveLength(3)
  })

  it('separates dissimilar hashes', () => {
    const entries = [
      { photoId: 'a', hash: 'ffffffffffffffff' },
      { photoId: 'b', hash: '0000000000000000' },
    ]
    const result = clusterByHash(entries, 4, 2)
    expect(result.groups).toHaveLength(0)
    expect(result.ungrouped).toHaveLength(2)
  })

  it('respects minGroupSize', () => {
    const entries = [
      { photoId: 'a', hash: 'ffffffffffffffff' },
      { photoId: 'b', hash: 'fffffffffffffffe' },
    ]
    const result = clusterByHash(entries, 4, 3)
    // only 2 entries, need 3 for a group
    expect(result.groups).toHaveLength(0)
  })

  it('creates multiple clusters', () => {
    const entries = [
      { photoId: 'a1', hash: 'ffffffffffffffff' },
      { photoId: 'a2', hash: 'fffffffffffffffe' },
      { photoId: 'b1', hash: '0000000000000000' },
      { photoId: 'b2', hash: '0000000000000001' },
    ]
    const result = clusterByHash(entries, 3, 2)
    expect(result.groups).toHaveLength(2)
    const groupIds = result.groups.map(g => g.sort().join(',')).sort()
    expect(groupIds).toEqual(['a1,a2', 'b1,b2'])
  })

  it('handles empty input', () => {
    const result = clusterByHash([], 4, 2)
    expect(result.groups).toHaveLength(0)
    expect(result.ungrouped).toHaveLength(0)
  })
})
