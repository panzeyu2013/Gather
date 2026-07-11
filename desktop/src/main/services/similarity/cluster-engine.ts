import { hammingDistance } from './hash-computer'

export interface HashEntry {
  photoId: string
  hash: string
}

export function clusterByHash(
  entries: HashEntry[],
  threshold: number,
  minGroupSize: number,
): { groups: string[][]; ungrouped: string[] } {
  const visited = new Set<string>()
  const clustered = new Set<string>()
  const groups: string[][] = []
  const entryMap = new Map(entries.map((e) => [e.photoId, e]))

  for (const entry of entries) {
    if (visited.has(entry.photoId)) continue
    visited.add(entry.photoId)

    const neighbors = regionQuery(entry, entries, threshold)

    if (neighbors.length + 1 < minGroupSize) continue

    const group = [entry.photoId]
    clustered.add(entry.photoId)
    const seedList = [...neighbors]

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
      const currentNeighbors = regionQuery(currentEntry, entries, threshold)

      if (currentNeighbors.length + 1 >= minGroupSize) {
        for (const n of currentNeighbors) {
          if (!visited.has(n)) {
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

function regionQuery(entry: HashEntry, entries: HashEntry[], threshold: number): string[] {
  return entries
    .filter(
      (e) =>
        e.photoId !== entry.photoId &&
        hammingDistance(entry.hash, e.hash) <= threshold,
    )
    .map((e) => e.photoId)
}
