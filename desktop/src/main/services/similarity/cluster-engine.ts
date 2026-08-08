export interface HashEntry {
  photoId: string
  hash: string
}

export type HashGroupingMode = 'sequential' | 'global'

// Each hash is expanded once into bytes (big-endian) so the hot pairwise
// loops only touch flat byte memory; distances are table lookups instead of
// per-bit BigInt shifts. Hashes are normalized to the widest byte count seen
// in the batch (64-bit dHashes use the common 8-byte layout).
const MAX_BITSET_ENTRIES = 32768

const POPCOUNT_TABLE = buildPopcountTable()
const POPCOUNT_TABLE_16 = buildPopcountTable16()
const BIT_POSITIONS = buildBitPositions()

function buildPopcountTable(): Uint8Array {
  const table = new Uint8Array(256)
  for (let value = 1; value < 256; value++) {
    table[value] = table[value >> 1] + (value & 1)
  }
  return table
}

// 16-bit popcount lookup: halves the lookups per distance for the common
// 64-bit hashes (4 lookups instead of 8).
function buildPopcountTable16(): Uint8Array {
  const table = new Uint8Array(65536)
  for (let value = 1; value < 65536; value++) {
    table[value] = table[value >> 1] + (value & 1)
  }
  return table
}

// Precomputed set-bit positions per byte so bitset rows can be iterated over
// set bits only instead of per-index mask checks.
function buildBitPositions(): Uint8Array[] {
  const positions: Uint8Array[] = []
  for (let byte = 0; byte < 256; byte++) {
    const list = new Uint8Array(8)
    let count = 0
    for (let bit = 0; bit < 8; bit++) {
      if (byte & (1 << bit)) list[count++] = bit
    }
    positions.push(list.subarray(0, count))
  }
  return positions
}

// Hashes are stored big-endian, but the hamming distance is symmetric so byte
// order does not affect the result. Wide hashes are zero-padded to the batch
// byte count, which reproduces the previous BigInt comparison exactly.
function writeHashBytes(
  data: Uint8Array,
  offset: number,
  hash: string,
  byteCount: number,
): void {
  let value = BigInt(`0x${hash}`)
  for (let byte = byteCount - 1; byte >= 0; byte--) {
    data[offset + byte] = Number(value & 0xffn)
    value >>= 8n
  }
}

function hashByteCount(hash: string): number {
  return Math.max(1, Math.ceil(hash.length / 2))
}

// view16 is a Uint16Array alias of `data` for the common 8-byte layout; the
// byte grouping is endian-agnostic because the popcount is bitwise.
function hammingDistanceAt(
  data: Uint8Array,
  view16: Uint16Array | null,
  offsetA: number,
  offsetB: number,
  byteCount: number,
): number {
  if (byteCount === 8 && view16) {
    const table16 = POPCOUNT_TABLE_16
    const wordA = offsetA >> 1
    const wordB = offsetB >> 1
    return (
      table16[view16[wordA] ^ view16[wordB]] +
      table16[view16[wordA + 1] ^ view16[wordB + 1]] +
      table16[view16[wordA + 2] ^ view16[wordB + 2]] +
      table16[view16[wordA + 3] ^ view16[wordB + 3]]
    )
  }
  const table = POPCOUNT_TABLE
  let distance = 0
  for (let byte = 0; byte < byteCount; byte++) {
    distance += table[data[offsetA + byte] ^ data[offsetB + byte]]
  }
  return distance
}

export function clusterByHash(
  entries: HashEntry[],
  threshold: number,
  minGroupSize: number,
  mode: HashGroupingMode = 'global',
  onProgress?: (current: number, total: number) => void,
  // Test hook: forces the recomputed (n > 32768) path on smaller inputs so
  // both code paths can be exercised without allocating the bitset matrix.
  maxBitsetEntries: number = MAX_BITSET_ENTRIES,
): { groups: string[][]; ungrouped: string[] } {
  const count = entries.length
  let bytesPerHash = 8
  for (let i = 0; i < count; i++) {
    const byteCount = hashByteCount(entries[i].hash)
    if (byteCount > bytesPerHash) bytesPerHash = byteCount
  }
  const data = new Uint8Array(count * bytesPerHash)
  const view16 = bytesPerHash === 8
    ? new Uint16Array(data.buffer, 0, data.length >> 1)
    : null
  const ids = new Array<string>(count)
  for (let i = 0; i < count; i++) {
    writeHashBytes(data, i * bytesPerHash, entries[i].hash, bytesPerHash)
    ids[i] = entries[i].photoId
  }
  if (mode === 'sequential') {
    return clusterSequentially(ids, data, view16, threshold, minGroupSize, bytesPerHash, onProgress)
  }
  if (count <= maxBitsetEntries) {
    return clusterGloballyWithBitsets(
      ids,
      data,
      view16,
      threshold,
      minGroupSize,
      bytesPerHash,
      onProgress,
    )
  }
  return clusterGloballyRecomputed(
    ids,
    data,
    view16,
    threshold,
    minGroupSize,
    bytesPerHash,
    onProgress,
  )
}

/**
 * Cluster the same entries under several thresholds at once. The pairwise
 * Hamming pass is threshold-independent: a single triangular pass computes
 * each distance once and fans it out to every threshold's region sizes, so
 * the k tiers cost one distance pass instead of k (the 4-way neighbor-tier
 * precomputation in similarity.service is the main consumer).
 *
 * Sequential mode and the bitset path (small inputs, memory-bound) keep their
 * per-threshold loops — the bitset matrix cannot be shared without multiplying
 * memory k-fold — but the recomputed path (the one that runs for large
 * sessions) shares the distance pass. Returns one result per entry of
 * `thresholds` (duplicates are clustered once and mapped back).
 *
 * Progress totals are `count * (1 + thresholds.length)` units: one pass of
 * `count` units, then `count` units per tier, so callers never see a
 * non-monotonic bar across the whole batch.
 */
export function clusterByHashMulti(
  entries: HashEntry[],
  thresholds: number[],
  minGroupSize: number,
  mode: HashGroupingMode = 'global',
  onProgress?: (current: number, total: number) => void,
  // Test hook: forces the recomputed (n > maxBitsetEntries) path on smaller
  // inputs so both code paths can be exercised without allocating the bitset
  // matrix (mirrors clusterByHash).
  maxBitsetEntries: number = MAX_BITSET_ENTRIES,
): Array<{ groups: string[][]; ungrouped: string[] }> {
  const unique = [...new Set(thresholds)].sort((a, b) => a - b)
  const count = entries.length
  const empty: Array<{ groups: string[][]; ungrouped: string[] }> =
    thresholds.map(() => ({ groups: [], ungrouped: [] }))
  if (count === 0 || unique.length === 0) return empty
  const perTierUnits = count
  const totalUnits = count * (unique.length + 1)

  // The bitset path reports per-tier progress on a 0..2n scale (distance
  // pass, then BFS with cumulative assigned counts that may dip below the
  // pass end); clamping to a monotonic sequence keeps the UI bar stable.
  let lastProgress = 0
  const progressForTier = (tierIndex: number, tierCurrent: number): void => {
    const mapped = count + tierIndex * perTierUnits + Math.min(tierCurrent, perTierUnits)
    if (mapped > lastProgress) lastProgress = mapped
    onProgress?.(lastProgress, totalUnits)
  }

  let bytesPerHash = 8
  for (let i = 0; i < count; i++) {
    const byteCount = hashByteCount(entries[i].hash)
    if (byteCount > bytesPerHash) bytesPerHash = byteCount
  }
  const data = new Uint8Array(count * bytesPerHash)
  const view16 = bytesPerHash === 8
    ? new Uint16Array(data.buffer, 0, data.length >> 1)
    : null
  const ids = new Array<string>(count)
  for (let i = 0; i < count; i++) {
    writeHashBytes(data, i * bytesPerHash, entries[i].hash, bytesPerHash)
    ids[i] = entries[i].photoId
  }

  if (mode === 'sequential') {
    return thresholds.map((tier, tierIndex) => {
      const result = clusterSequentially(
        ids, data, view16, tier, minGroupSize, bytesPerHash,
        (current) => progressForTier(tierIndex, current),
      )
      progressForTier(tierIndex, perTierUnits)
      return result
    })
  }
  if (count <= maxBitsetEntries) {
    return thresholds.map((tier, tierIndex) => {
      const result = clusterGloballyWithBitsets(
        ids, data, view16, tier, minGroupSize, bytesPerHash,
        (current) => progressForTier(tierIndex, current),
      )
      progressForTier(tierIndex, perTierUnits)
      return result
    })
  }
  const results = clusterGloballyRecomputedMulti(
    ids, data, view16, unique, minGroupSize, bytesPerHash, onProgress, totalUnits,
  )
  // Map back to the caller's threshold order (with duplicate handling).
  const byTier = new Map(unique.map((tier, index) => [tier, results[index]]))
  return thresholds.map(tier => byTier.get(tier)!)
}

// Sequential mode keeps the previous semantics: consecutive entries whose
// adjacent hashes are within threshold merge into one run.
function clusterSequentially(
  ids: string[],
  data: Uint8Array,
  view16: Uint16Array | null,
  threshold: number,
  minGroupSize: number,
  bytesPerHash: number,
  onProgress?: (current: number, total: number) => void,
): { groups: string[][]; ungrouped: string[] } {
  if (ids.length === 0) return { groups: [], ungrouped: [] }
  const groups: string[][] = []
  const ungrouped: string[] = []
  let run: string[] = [ids[0]]

  const flush = (): void => {
    if (run.length >= minGroupSize) groups.push(run)
    else ungrouped.push(...run)
  }

  for (let index = 1; index < ids.length; index++) {
    if (index % 1024 === 0) {
      onProgress?.(index, ids.length)
    }
    const previousOffset = (index - 1) * bytesPerHash
    const currentOffset = index * bytesPerHash
    if (hammingDistanceAt(data, view16, previousOffset, currentOffset, bytesPerHash) <= threshold) {
      run.push(ids[index])
    } else {
      flush()
      run = [ids[index]]
    }
  }
  flush()
  onProgress?.(ids.length, ids.length)
  return { groups, ungrouped }
}

// Brute-force pairwise distance pass building per-entry bit rows, then a
// wave-based BFS over those rows (each expanded node ORs its whole neighbor
// row into the next frontier at once). This eliminates the BK-tree radius
// window that degenerated to near O(n^2) neighbor searches at high thresholds
// while keeping exactly the same connected-component semantics (dense seeds
// expand, sparse boundary members still join the group).
function clusterGloballyWithBitsets(
  ids: string[],
  data: Uint8Array,
  view16: Uint16Array | null,
  threshold: number,
  minGroupSize: number,
  bytesPerHash: number,
  onProgress?: (current: number, total: number) => void,
): { groups: string[][]; ungrouped: string[] } {
  const count = ids.length
  if (count === 0) return { groups: [], ungrouped: [] }

  // Aligned to 32-bit words so the BFS can OR whole rows through a Uint32
  // view instead of byte-by-byte.
  const rowBytes = ((count + 7) >> 3) + 3 & ~3
  const rows = new Uint8Array(count * rowBytes)
  const regionSizes = new Uint32Array(count)
  const step = Math.max(512, Math.floor(count * 0.02))

  for (let i = 0; i < count; i++) {
    if ((i + 1) % step === 0 || i + 1 === count) {
      onProgress?.(i + 1, count)
    }
    const offsetA = i * bytesPerHash
    const rowBase = i * rowBytes
    for (let j = i + 1; j < count; j++) {
      if (hammingDistanceAt(data, view16, offsetA, j * bytesPerHash, bytesPerHash) <= threshold) {
        rows[rowBase + (j >> 3)] |= 1 << (j & 7)
        rows[j * rowBytes + (i >> 3)] |= 1 << (i & 7)
        regionSizes[i]++
        regionSizes[j]++
      }
    }
  }

  const grouped = waveBfsOverRows(ids, rows, rowBytes, regionSizes, minGroupSize, count, onProgress)
  // Final progress value so callers never observe the bar stuck below 100%.
  onProgress?.(count, count)
  return grouped
}

// Same algorithm for very large inputs where a full bitset matrix would not
// fit in memory: region sizes are computed in one triangular pass, then the
// neighbor lists of expanded nodes are recomputed on demand.
function clusterGloballyRecomputed(
  ids: string[],
  data: Uint8Array,
  view16: Uint16Array | null,
  threshold: number,
  minGroupSize: number,
  bytesPerHash: number,
  onProgress?: (current: number, total: number) => void,
): { groups: string[][]; ungrouped: string[] } {
  const count = ids.length
  if (count === 0) return { groups: [], ungrouped: [] }

  const regionSizes = new Uint32Array(count)
  const step = Math.max(512, Math.floor(count * 0.02))

  for (let i = 0; i < count; i++) {
    if ((i + 1) % step === 0 || i + 1 === count) {
      onProgress?.(i + 1, count * 2)
    }
    const offsetA = i * bytesPerHash
    for (let j = i + 1; j < count; j++) {
      if (hammingDistanceAt(data, view16, offsetA, j * bytesPerHash, bytesPerHash) <= threshold) {
        regionSizes[i]++
        regionSizes[j]++
      }
    }
  }

  const grouped = recomputedBfs(
    ids, data, view16, threshold, minGroupSize, bytesPerHash, regionSizes,
    (current) => onProgress?.(count + current, count * 2),
  )
  onProgress?.(count * 2, count * 2)
  return grouped
}

// Multi-threshold variant of clusterGloballyRecomputed: one triangular pass
// computes every pair's distance once and accumulates each threshold's region
// sizes (k x Uint32Array(count) — a few MB even at 100k entries), then each
// tier runs the same on-demand BFS as the single-threshold path.
function clusterGloballyRecomputedMulti(
  ids: string[],
  data: Uint8Array,
  view16: Uint16Array | null,
  thresholds: number[],
  minGroupSize: number,
  bytesPerHash: number,
  onProgress?: (current: number, total: number) => void,
  totalUnits?: number,
): Array<{ groups: string[][]; ungrouped: string[] }> {
  const count = ids.length
  const tiers = thresholds.length
  const units = totalUnits ?? count * (tiers + 1)
  if (count === 0) return thresholds.map(() => ({ groups: [], ungrouped: [] }))

  const regionSizesByTier = thresholds.map(() => new Uint32Array(count))
  const step = Math.max(512, Math.floor(count * 0.02))

  for (let i = 0; i < count; i++) {
    if ((i + 1) % step === 0 || i + 1 === count) {
      onProgress?.(i + 1, units)
    }
    const offsetA = i * bytesPerHash
    for (let j = i + 1; j < count; j++) {
      const distance = hammingDistanceAt(data, view16, offsetA, j * bytesPerHash, bytesPerHash)
      for (let tierIndex = 0; tierIndex < tiers; tierIndex++) {
        if (distance <= thresholds[tierIndex]) {
          regionSizesByTier[tierIndex][i]++
          regionSizesByTier[tierIndex][j]++
        }
      }
    }
  }

  const results: Array<{ groups: string[][]; ungrouped: string[] }> = []
  for (let tierIndex = 0; tierIndex < tiers; tierIndex++) {
    results.push(recomputedBfs(
      ids, data, view16, thresholds[tierIndex], minGroupSize, bytesPerHash,
      regionSizesByTier[tierIndex],
      (current) => onProgress?.(count + tierIndex * count + Math.min(current, count), units),
    ))
    onProgress?.(count + (tierIndex + 1) * count, units)
  }
  return results
}

// BFS shared by the single- and multi-threshold recomputed paths: dense seeds
// (region size >= minGroupSize - 1) expand by recomputing neighbor lists on
// demand; sparse nodes join the group without expanding. Pure graph semantics
// matching the wave BFS: any node on the frontier joins the group, so
// expansion must not skip nodes that were merely marked visited by an earlier
// seed check (sparse nodes whose index precedes the seed are
// visited-but-ungrouped).
function recomputedBfs(
  ids: string[],
  data: Uint8Array,
  view16: Uint16Array | null,
  threshold: number,
  minGroupSize: number,
  bytesPerHash: number,
  regionSizes: Uint32Array,
  onProgress?: (current: number, total: number) => void,
): { groups: string[][]; ungrouped: string[] } {
  const count = ids.length
  const neighbors = (index: number): number[] => {
    const result: number[] = []
    const offsetA = index * bytesPerHash
    for (let j = 0; j < count; j++) {
      if (j === index) continue
      if (hammingDistanceAt(data, view16, offsetA, j * bytesPerHash, bytesPerHash) <= threshold) {
        result.push(j)
      }
    }
    return result
  }

  const visited = new Uint8Array(count)
  const clustered = new Uint8Array(count)
  const queued = new Uint8Array(count)
  const groups: string[][] = []
  const seedStack: number[] = []

  for (let i = 0; i < count; i++) {
    if (visited[i]) continue
    visited[i] = 1
    if (regionSizes[i] + 1 < minGroupSize) continue

    const group = [ids[i]]
    clustered[i] = 1
    seedStack.length = 0
    const seedNeighbors = neighbors(i)
    for (const neighbor of seedNeighbors) {
      queued[neighbor] = 1
      seedStack.push(neighbor)
    }
    while (seedStack.length > 0) {
      const current = seedStack.pop()!
      if (visited[current]) {
        if (!clustered[current]) {
          group.push(ids[current])
          clustered[current] = 1
        }
        continue
      }
      visited[current] = 1
      if (regionSizes[current] + 1 >= minGroupSize) {
        const currentNeighbors = neighbors(current)
        for (const neighbor of currentNeighbors) {
          if (!clustered[neighbor] && !queued[neighbor]) {
            queued[neighbor] = 1
            seedStack.push(neighbor)
          }
        }
      }
      if (!clustered[current]) {
        group.push(ids[current])
        clustered[current] = 1
      }
    }
    groups.push(group)
    onProgress?.(i + 1, count)
  }

  const ungrouped: string[] = []
  for (let i = 0; i < count; i++) {
    if (!clustered[i]) ungrouped.push(ids[i])
  }
  return { groups, ungrouped }
}

// Wave BFS: at each level the neighbor rows of all dense frontier nodes are
// ORed into the next frontier in 32-bit words, then every frontier node joins
// the group. Nodes whose region is below minGroupSize join but do not expand,
// matching the previous stack-based BFS exactly.
function waveBfsOverRows(
  ids: string[],
  rows: Uint8Array,
  rowBytes: number,
  regionSizes: Uint32Array,
  minGroupSize: number,
  count: number,
  onProgress?: (current: number, total: number) => void,
): { groups: string[][]; ungrouped: string[] } {
  const rowWords = rowBytes >> 2
  const inGroup = new Uint8Array(count)
  const groups: string[][] = []
  const ungrouped: string[] = []
  let assigned = 0

  const rowView = new Uint32Array(rows.buffer)
  const memberBits = new Uint8Array(rowBytes)
  const frontierBits = new Uint8Array(rowBytes)
  const nextBits = new Uint8Array(rowBytes)
  const memberView = new Uint32Array(memberBits.buffer)
  const frontierView = new Uint32Array(frontierBits.buffer)
  const nextView = new Uint32Array(nextBits.buffer)

  const bitPositions = BIT_POSITIONS

  for (let seed = 0; seed < count; seed++) {
    if (inGroup[seed]) continue
    if (regionSizes[seed] + 1 < minGroupSize) continue

    const group = [ids[seed]]
    inGroup[seed] = 1
    memberBits.fill(0)
    frontierBits.fill(0)
    memberView[seed >> 5] |= 1 << (seed & 31)
    // Initial frontier: the seed's neighbors.
    frontierBits.set(rows.subarray(seed * rowBytes, seed * rowBytes + rowBytes))

    let hasFrontier = true
    while (hasFrontier) {
      nextBits.fill(0)
      // Adopt every frontier node and OR the rows of dense ones into the
      // next frontier; sparse nodes join the group without expanding.
      for (let byteOff = 0; byteOff < rowBytes; byteOff++) {
        const byte = frontierBits[byteOff]
        if (byte === 0) continue
        const base = byteOff << 3
        const positions = bitPositions[byte]
        for (let k = 0; k < positions.length; k++) {
          const node = base | positions[k]
          if (inGroup[node]) continue
          inGroup[node] = 1
          memberView[node >> 5] |= 1 << (node & 31)
          group.push(ids[node])
          assigned++
          if (regionSizes[node] + 1 >= minGroupSize) {
            const rowBase = node * rowWords
            for (let word = 0; word < rowWords; word++) {
              nextView[word] |= rowView[rowBase + word]
            }
          }
        }
      }
      // Next frontier: neighbors discovered this wave that are not yet
      // members of the group.
      hasFrontier = false
      for (let word = 0; word < rowWords; word++) {
        const nextWord = nextView[word] & ~memberView[word]
        frontierView[word] = nextWord
        if (nextWord !== 0) hasFrontier = true
      }
    }
    groups.push(group)
    onProgress?.(assigned, count)
  }

  for (let i = 0; i < count; i++) {
    if (!inGroup[i]) ungrouped.push(ids[i])
  }
  return { groups, ungrouped }
}
