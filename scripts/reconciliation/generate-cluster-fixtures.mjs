#!/usr/bin/env node
// scripts/reconciliation/generate-cluster-fixtures.mjs
// dHash 聚类对账 fixture 生成器（Phase 1 任务 1.5「对账测试框架」第二批）。
//
// 对账模式：同一 fixture 输入双跑（TS vitest ↔ Swift Testing）。
// 本生成器产出 dHash 聚类引擎的纯核心循环 fixture：确定性伪随机 16 位 hex
// 哈希串集合（覆盖同簇/边界/空输入/单元素/宽哈希/混合宽度/奇数字符数）→
// 分组结果，入库到 desktop/native/gather-core/Tests/GatherCoreTests/
// Reconciliation/Fixtures/cluster-fixtures.json，Swift 侧
// ClusterReconciliationTests 加载同一 JSON 逐 case 比对。
//
// 聚类判定标准：两条哈希的汉明距离（逐位 XOR 的 popcount）≤ threshold 即连边；
// global 模式 = 阈值图的连通分量（wave BFS），sequential 模式 = 相邻阈值内连续段。
// 详见参照实现注释。
//
// 用法：
//   node scripts/reconciliation/generate-cluster-fixtures.mjs            # 生成/覆盖 fixture
//   node scripts/reconciliation/generate-cluster-fixtures.mjs --check    # 重算比对，漂移退出 1

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const SEED = 20260809

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(SCRIPT_DIR, '..', '..')
const FIXTURE_PATH = path.join(
  ROOT,
  'desktop', 'native', 'gather-core',
  'Tests', 'GatherCoreTests', 'Reconciliation', 'Fixtures',
  'cluster-fixtures.json',
)

// ─────────────────────────────────────────────────────────────────────────────
// 参照实现：从 desktop/src/main/services/similarity/cluster-engine.ts 照抄
// （仅去 TS 类型标注），各函数行号指向 TS 源文件。该文件无任何第三方依赖，
// 核心循环逐字等价。
//
// fixture 输入规模均 ≤ MAX_BITSET_ENTRIES（bitset 路径），故只照抄
// clusterByHash / clusterByHashMulti 的 sequential 与 bitset 路径；
// clusterGloballyRecomputed* / recomputedBfs（TS:327-495）在 fixture 规模下
// 不会命中，若未来 fixture 加入超大输入再补齐。
// ─────────────────────────────────────────────────────────────────────────────

// TS:12
const MAX_BITSET_ENTRIES = 32768

// TS:14-24
function buildPopcountTable() {
  const table = new Uint8Array(256)
  for (let value = 1; value < 256; value++) {
    table[value] = table[value >> 1] + (value & 1)
  }
  return table
}

// TS:28-34
function buildPopcountTable16() {
  const table = new Uint8Array(65536)
  for (let value = 1; value < 65536; value++) {
    table[value] = table[value >> 1] + (value & 1)
  }
  return table
}

// TS:38-49
function buildBitPositions() {
  const positions = []
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

const POPCOUNT_TABLE = buildPopcountTable()
const POPCOUNT_TABLE_16 = buildPopcountTable16()
const BIT_POSITIONS = buildBitPositions()

// TS:54-65
function writeHashBytes(data, offset, hash, byteCount) {
  let value = BigInt(`0x${hash}`)
  for (let byte = byteCount - 1; byte >= 0; byte--) {
    data[offset + byte] = Number(value & 0xffn)
    value >>= 8n
  }
}

// TS:67-69
function hashByteCount(hash) {
  return Math.max(1, Math.ceil(hash.length / 2))
}

// TS:73-97
function hammingDistanceAt(data, view16, offsetA, offsetB, byteCount) {
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

// TS:240-275
function clusterSequentially(ids, data, view16, threshold, minGroupSize, bytesPerHash, onProgress) {
  if (ids.length === 0) return { groups: [], ungrouped: [] }
  const groups = []
  const ungrouped = []
  let run = [ids[0]]

  const flush = () => {
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

// TS:283-322
function clusterGloballyWithBitsets(ids, data, view16, threshold, minGroupSize, bytesPerHash, onProgress) {
  const count = ids.length
  if (count === 0) return { groups: [], ungrouped: [] }

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
  onProgress?.(count, count)
  return grouped
}

// TS:501-579
function waveBfsOverRows(ids, rows, rowBytes, regionSizes, minGroupSize, count, onProgress) {
  const rowWords = rowBytes >> 2
  const inGroup = new Uint8Array(count)
  const groups = []
  const ungrouped = []
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
    frontierBits.set(rows.subarray(seed * rowBytes, seed * rowBytes + rowBytes))

    let hasFrontier = true
    while (hasFrontier) {
      nextBits.fill(0)
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

// TS:99-147（maxBitsetEntries 测试钩子保留默认值）
function clusterByHash(entries, threshold, minGroupSize, mode = 'global', onProgress, maxBitsetEntries = MAX_BITSET_ENTRIES) {
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
  const ids = new Array(count)
  for (let i = 0; i < count; i++) {
    writeHashBytes(data, i * bytesPerHash, entries[i].hash, bytesPerHash)
    ids[i] = entries[i].photoId
  }
  if (mode === 'sequential') {
    return clusterSequentially(ids, data, view16, threshold, minGroupSize, bytesPerHash, onProgress)
  }
  if (count <= maxBitsetEntries) {
    return clusterGloballyWithBitsets(ids, data, view16, threshold, minGroupSize, bytesPerHash, onProgress)
  }
  throw new Error('generate-cluster-fixtures: fixture 规模超过 bitset 路径上限，需补齐重算路径参照实现')
}

// TS:166-236（同上：仅 bitset/sequential 路径）
function clusterByHashMulti(entries, thresholds, minGroupSize, mode = 'global', onProgress, maxBitsetEntries = MAX_BITSET_ENTRIES) {
  const unique = [...new Set(thresholds)].sort((a, b) => a - b)
  const count = entries.length
  const empty = thresholds.map(() => ({ groups: [], ungrouped: [] }))
  if (count === 0 || unique.length === 0) return empty

  let bytesPerHash = 8
  for (let i = 0; i < count; i++) {
    const byteCount = hashByteCount(entries[i].hash)
    if (byteCount > bytesPerHash) bytesPerHash = byteCount
  }
  const data = new Uint8Array(count * bytesPerHash)
  const view16 = bytesPerHash === 8
    ? new Uint16Array(data.buffer, 0, data.length >> 1)
    : null
  const ids = new Array(count)
  for (let i = 0; i < count; i++) {
    writeHashBytes(data, i * bytesPerHash, entries[i].hash, bytesPerHash)
    ids[i] = entries[i].photoId
  }

  if (mode === 'sequential') {
    return thresholds.map((tier) => clusterSequentially(ids, data, view16, tier, minGroupSize, bytesPerHash))
  }
  if (count <= maxBitsetEntries) {
    return thresholds.map((tier) => clusterGloballyWithBitsets(ids, data, view16, tier, minGroupSize, bytesPerHash))
  }
  throw new Error('generate-cluster-fixtures: fixture 规模超过 bitset 路径上限，需补齐重算路径参照实现')
}

// ─────────────────────────────────────────────────────────────────────────────
// 确定性输入构造
// ─────────────────────────────────────────────────────────────────────────────

function mulberry32(seed) {
  let a = seed >>> 0
  return function () {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomHex(rand, length) {
  let s = ''
  for (let i = 0; i < length; i++) s += Math.floor(rand() * 16).toString(16)
  return s
}

// 翻转指定 hex 字符位（每项恰好翻转 1 bit；flips 之间 pos 互不重叠时，
// 与基哈希的距离 = flips 项数）。
function flipBits(hex, flips) {
  const chars = hex.split('')
  for (const { pos, mask } of flips) {
    chars[pos] = (parseInt(chars[pos], 16) ^ mask).toString(16)
  }
  return chars.join('')
}

// 校验辅助：两条哈希的汉明距离（仅生成器内部校验用，不属于参照实现）。
function hammingHex(a, b) {
  let x = BigInt(`0x${a}`) ^ BigInt(`0x${b}`)
  let count = 0
  while (x > 0n) {
    x &= x - 1n
    count++
  }
  return count
}

function entry(photoId, hash) {
  return { photoId, hash }
}

function caseOf(name, entries, threshold, minGroupSize, mode) {
  return {
    name,
    mode,
    threshold,
    minGroupSize,
    entries,
    expected: clusterByHash(entries, threshold, minGroupSize, mode),
  }
}

function multiCaseOf(name, entries, thresholds, minGroupSize, mode) {
  return {
    name,
    mode,
    thresholds,
    minGroupSize,
    entries,
    expected: clusterByHashMulti(entries, thresholds, minGroupSize, mode),
  }
}

function buildCases(rand) {
  const cases = []
  const multiCases = []

  // --- 空输入（两种模式）
  cases.push(caseOf('empty-global', [], 4, 2, 'global'))
  cases.push(caseOf('empty-sequential', [], 4, 2, 'sequential'))

  // --- 单元素（minGroupSize 1 / 2）
  const solo = randomHex(rand, 16)
  cases.push(caseOf('single-min1', [entry('solo', solo)], 4, 1, 'global'))
  cases.push(caseOf('single-min2', [entry('solo', solo)], 4, 2, 'global'))

  // --- 相同哈希 + 一个远点（阈值 0：仅完全相同者同簇）
  const dup = randomHex(rand, 16)
  const far = randomHex(rand, 16)
  if (dup === far) throw new Error('fatal: dup 与 far 意外相同')
  cases.push(caseOf('identical-threshold0', [
    entry('d0', dup),
    entry('d1', dup),
    entry('far', far),
  ], 0, 2, 'global'))

  // --- 星型 1-bit 邻居（阈值 1：三成员各自距中心 1 bit → 全簇）
  const h0 = randomHex(rand, 16)
  const h1 = flipBits(h0, [{ pos: 0, mask: 1 }])
  const h2 = flipBits(h0, [{ pos: 1, mask: 1 }])
  cases.push(caseOf('star-threshold1', [
    entry('h0', h0),
    entry('h1', h1),
    entry('h2', h2),
  ], 1, 2, 'global'))

  // --- 4 元素簇：base 与其余成员距离 1，其余两两距离 2
  //     （threshold 2 → 全连通成组；threshold 1 → base 为星型中心仍全成组）
  const base = randomHex(rand, 16)
  const c1 = flipBits(base, [{ pos: 4, mask: 1 }])
  const c2 = flipBits(base, [{ pos: 5, mask: 2 }])
  const c3 = flipBits(base, [{ pos: 6, mask: 4 }])
  const cluster4 = [entry('c0', base), entry('c1', c1), entry('c2', c2), entry('c3', c3)]
  cases.push(caseOf('cluster4-threshold2-min3', cluster4, 2, 3, 'global'))
  cases.push(caseOf('cluster4-threshold1-min3', cluster4, 1, 3, 'global'))

  // --- 精确边界对：距离恰为 4 bits（threshold 4 → 同簇；3 → 分离）
  const b0 = randomHex(rand, 16)
  const b1 = flipBits(b0, [
    { pos: 0, mask: 1 },
    { pos: 1, mask: 1 },
    { pos: 2, mask: 1 },
    { pos: 3, mask: 1 },
  ])
  const boundaryPair = [entry('b0', b0), entry('b1', b1)]
  cases.push(caseOf('boundary-pair-threshold4', boundaryPair, 4, 2, 'global'))
  cases.push(caseOf('boundary-pair-threshold3', boundaryPair, 3, 2, 'global'))

  // --- 混合批次：4 元素簇 + 边界对 + 孤立点 + 两个随机远点 + 相同对
  const s0 = randomHex(rand, 16)
  const x0 = randomHex(rand, 16)
  const x1 = randomHex(rand, 16)
  const mixed = [
    ...cluster4,
    ...boundaryPair,
    entry('s0', s0),
    entry('x0', x0),
    entry('x1', x1),
    entry('d0', dup),
    entry('d1', dup),
  ]
  cases.push(caseOf('mixed-threshold2', mixed, 2, 2, 'global'))
  cases.push(caseOf('mixed-threshold4', mixed, 4, 2, 'global'))
  multiCases.push(multiCaseOf('mixed-tiers', mixed, [0, 2, 4], 2, 'global'))

  // --- burst（与 tests/unit/services/similarity/cluster-engine.test.ts:54-79 同款输入：
  //     sequential 按连续段分两组，global 合并为一组）
  const burst = [
    entry('burst-a1', 'ffffffffffffffff'),
    entry('burst-a2', 'fffffffffffffffe'),
    entry('break', '0000000000000000'),
    entry('burst-a3', 'ffffffffffffffff'),
    entry('burst-a4', 'fffffffffffffffe'),
  ]
  cases.push(caseOf('burst-sequential', burst, 2, 2, 'sequential'))
  cases.push(caseOf('burst-global', burst, 2, 2, 'global'))
  multiCases.push(multiCaseOf('burst-tiers-sequential', burst, [1, 2], 2, 'sequential'))

  // --- 16 字节（32 hex）宽哈希簇：两两距离 1-2 bits
  const wideBase = randomHex(rand, 32)
  const w1 = flipBits(wideBase, [{ pos: 8, mask: 1 }])
  const w2 = flipBits(wideBase, [{ pos: 9, mask: 2 }])
  const w3 = flipBits(wideBase, [{ pos: 10, mask: 4 }])
  const wideCluster = [entry('w0', wideBase), entry('w1', w1), entry('w2', w2), entry('w3', w3)]
  cases.push(caseOf('wide-cluster-threshold2', wideCluster, 2, 2, 'global'))

  // --- 混合宽度：32 hex 高半全 0 的哈希 ≡ 16 hex 后缀（零填充语义 → 距离 0）
  const suffix = randomHex(rand, 16)
  const padded = '0000000000000000' + suffix
  cases.push(caseOf('wide-padded-equal-threshold0', [
    entry('wide', padded),
    entry('short', suffix),
  ], 0, 2, 'global'))
  multiCases.push(multiCaseOf(
    'wide-tiers',
    [...wideCluster, entry('wide', padded), entry('short', suffix)],
    [0, 2], 2, 'global',
  ))

  // --- 奇数字符数 hex（15 位，最低 nibble 翻转 1 bit）
  const odd = randomHex(rand, 15)
  const oddSib = flipBits(odd, [{ pos: 14, mask: 1 }])
  cases.push(caseOf('odd-length-hex-threshold1', [
    entry('odd', odd),
    entry('odd-sib', oddSib),
  ], 1, 2, 'global'))

  return { cases, multiCases }
}

// ─────────────────────────────────────────────────────────────────────────────
// 校验
// ─────────────────────────────────────────────────────────────────────────────

function validatePartition(entries, expected) {
  const seen = new Set()
  for (const group of expected.groups) {
    if (group.length < 1) throw new Error('fatal: 空分组')
    for (const id of group) {
      if (seen.has(id)) throw new Error(`fatal: photoId ${id} 重复出现`)
      seen.add(id)
    }
  }
  for (const id of expected.ungrouped) {
    if (seen.has(id)) throw new Error(`fatal: photoId ${id} 重复出现`)
    seen.add(id)
  }
  if (seen.size !== entries.length) {
    throw new Error(`fatal: 分组结果条目数 ${seen.size} != 输入 ${entries.length}`)
  }
}

function assertDistances(entries, pairs, exact) {
  for (const [i, j] of pairs) {
    const actual = hammingHex(entries[i].hash, entries[j].hash)
    const expect = exact[`${i},${j}`]
    if (actual !== expect) {
      throw new Error(`fatal: 距离断言 ${i}-${j} 期望 ${expect} 实际 ${actual}`)
    }
  }
}

// 跨意图距离断言：mixed 批次中不同意图的成员对必须 > 4，避免随机哈希
// 意外落入阈值形成未预期的边（种子漂移时立即失败）。
function assertCrossDistances(entries, intents, minDistance) {
  for (let i = 0; i < entries.length; i++) {
    for (let j = i + 1; j < entries.length; j++) {
      if (intents[i] === intents[j]) continue
      const actual = hammingHex(entries[i].hash, entries[j].hash)
      if (actual <= minDistance) {
        throw new Error(`fatal: 跨意图距离 ${i}-${j} = ${actual} ≤ ${minDistance}`)
      }
    }
  }
}

function validate() {
  const rand = mulberry32(SEED)
  const { cases, multiCases } = buildCases(rand)

  const byName = new Map(cases.map((c) => [c.name, c]))
  const mByName = new Map(multiCases.map((c) => [c.name, c]))

  for (const c of cases) {
    for (const e of c.entries) {
      if (!/^[0-9a-f]+$/.test(e.hash) || e.hash.length < 1) {
        throw new Error(`fatal: case ${c.name} 含非法 hex ${e.hash}`)
      }
    }
    validatePartition(c.entries, c.expected)
  }
  for (const c of multiCases) {
    if (c.expected.length !== c.thresholds.length) {
      throw new Error(`fatal: multi ${c.name} 结果层数与 thresholds 不符`)
    }
    for (const tier of c.expected) validatePartition(c.entries, tier)
  }

  // 受控距离断言（构造期保证，防止种子/算法漂移后静默失真）
  const cluster4 = byName.get('cluster4-threshold2-min3').entries
  assertDistances(cluster4, [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]], {
    '0,1': 1, '0,2': 1, '0,3': 1, '1,2': 2, '1,3': 2, '2,3': 2,
  })
  const star = byName.get('star-threshold1').entries
  assertDistances(star, [[0, 1], [0, 2], [1, 2]], { '0,1': 1, '0,2': 1, '1,2': 2 })
  const boundary = byName.get('boundary-pair-threshold4').entries
  assertDistances(boundary, [[0, 1]], { '0,1': 4 })
  const wide = byName.get('wide-cluster-threshold2').entries
  assertDistances(wide, [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]], {
    '0,1': 1, '0,2': 1, '0,3': 1, '1,2': 2, '1,3': 2, '2,3': 2,
  })
  const padded = byName.get('wide-padded-equal-threshold0').entries
  assertDistances(padded, [[0, 1]], { '0,1': 0 })
  const odd = byName.get('odd-length-hex-threshold1').entries
  assertDistances(odd, [[0, 1]], { '0,1': 1 })

  const mixed = byName.get('mixed-threshold2').entries
  const intents = [0, 0, 0, 0, 1, 1, 2, 3, 3, 4, 4]
  assertCrossDistances(mixed, intents, 4)

  const burstGlobal = byName.get('burst-global').expected
  if (burstGlobal.groups.length !== 1 || burstGlobal.groups[0].length !== 4) {
    throw new Error('fatal: burst-global 期望 1 组 4 成员')
  }
  const burstSeq = byName.get('burst-sequential').expected
  if (burstSeq.groups.length !== 2 || burstSeq.ungrouped.length !== 1) {
    throw new Error('fatal: burst-sequential 期望 2 组 + 1 未分组')
  }

  const mByNameMissing = mByName.has('mixed-tiers') ? '' : 'missing mixed-tiers'
  if (mByNameMissing) throw new Error(`fatal: ${mByNameMissing}`)

  return { cases, multiCases }
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

function main() {
  const check = process.argv.includes('--check')

  const { cases, multiCases } = validate()
  const json = JSON.stringify({
    seed: SEED,
    source: 'desktop/src/main/services/similarity/cluster-engine.ts',
    cases,
    multiCases,
  }, null, 2) + '\n'

  if (check) {
    if (!fs.existsSync(FIXTURE_PATH)) {
      console.error(`--check 失败：fixture 不存在 ${FIXTURE_PATH}（先运行生成模式）`)
      process.exit(1)
    }
    const existing = fs.readFileSync(FIXTURE_PATH, 'utf8')
    if (existing !== json) {
      console.error(
        `--check 失败：fixture 漂移（seed=${SEED}, ${cases.length} cases + ${multiCases.length} multiCases）\n` +
          `现有文件：${FIXTURE_PATH}\n请重新生成并提交。`,
      )
      process.exit(1)
    }
    console.log(`OK: ${cases.length} cases + ${multiCases.length} multiCases 与 ${FIXTURE_PATH} 完全一致（seed=${SEED}）`)
    return
  }

  fs.mkdirSync(path.dirname(FIXTURE_PATH), { recursive: true })
  fs.writeFileSync(FIXTURE_PATH, json)
  console.log(`已写入 ${FIXTURE_PATH}（seed=${SEED}, ${cases.length} cases + ${multiCases.length} multiCases）`)
}

main()
