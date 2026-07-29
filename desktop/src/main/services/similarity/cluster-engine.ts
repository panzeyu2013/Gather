export interface HashEntry {
  photoId: string
  hash: string
}

interface PreparedHashEntry extends HashEntry {
  value: bigint
}

interface HashTreeNode {
  entry: PreparedHashEntry
  children: Map<number, HashTreeNode>
}

function hammingDistanceValue(a: bigint, b: bigint): number {
  let value = a ^ b
  let count = 0
  while (value !== 0n) {
    value &= value - 1n
    count++
  }
  return count
}

class HashMetricIndex {
  private root: HashTreeNode | null = null

  add(entry: PreparedHashEntry): void {
    if (!this.root) {
      this.root = { entry, children: new Map() }
      return
    }
    let node = this.root
    for (;;) {
      const distance = hammingDistanceValue(entry.value, node.entry.value)
      const child = node.children.get(distance)
      if (!child) {
        node.children.set(distance, { entry, children: new Map() })
        return
      }
      node = child
    }
  }

  search(value: bigint, radius: number): PreparedHashEntry[] {
    if (!this.root) return []
    const matches: PreparedHashEntry[] = []
    const pending = [this.root]
    while (pending.length > 0) {
      const node = pending.pop()!
      const distance = hammingDistanceValue(value, node.entry.value)
      if (distance <= radius) matches.push(node.entry)
      const min = distance - radius
      const max = distance + radius
      for (const [edge, child] of node.children) {
        if (edge >= min && edge <= max) pending.push(child)
      }
    }
    return matches
  }
}

export function clusterByHash(
  entries: HashEntry[],
  threshold: number,
  minGroupSize: number,
): { groups: string[][]; ungrouped: string[] } {
  const prepared: PreparedHashEntry[] = entries.map(entry => ({
    ...entry,
    value: BigInt(`0x${entry.hash}`),
  }))
  const metricIndex = new HashMetricIndex()
  for (const entry of prepared) metricIndex.add(entry)
  const visited = new Set<string>()
  const clustered = new Set<string>()
  const groups: string[][] = []
  const entryMap = new Map(prepared.map((entry) => [entry.photoId, entry]))

  for (const entry of prepared) {
    if (visited.has(entry.photoId)) continue
    visited.add(entry.photoId)

    const neighbors = regionQuery(entry, metricIndex, threshold)

    if (neighbors.length + 1 < minGroupSize) continue

    const group = [entry.photoId]
    clustered.add(entry.photoId)
    const seedList = [...neighbors]
    const queued = new Set(seedList)

    while (seedList.length > 0) {
      const currentId = seedList.pop()!

      if (visited.has(currentId)) {
        if (!clustered.has(currentId)) {
          group.push(currentId)
          clustered.add(currentId)
        }
        continue
      }

      visited.add(currentId)
      const currentEntry = entryMap.get(currentId)!
      const currentNeighbors = regionQuery(currentEntry, metricIndex, threshold)

      if (currentNeighbors.length + 1 >= minGroupSize) {
        for (const n of currentNeighbors) {
          if (!visited.has(n) && !queued.has(n)) {
            queued.add(n)
            seedList.push(n)
          }
        }
      }

      if (!clustered.has(currentId)) {
        group.push(currentId)
        clustered.add(currentId)
      }
    }

    groups.push(group)
  }

  const ungrouped = entries
    .filter((e) => !clustered.has(e.photoId))
    .map((e) => e.photoId)

  return { groups, ungrouped }
}

function regionQuery(
  entry: PreparedHashEntry,
  index: HashMetricIndex,
  threshold: number,
): string[] {
  return index.search(entry.value, threshold)
    .filter(
      (e) =>
        e.photoId !== entry.photoId,
    )
    .map((e) => e.photoId)
}
