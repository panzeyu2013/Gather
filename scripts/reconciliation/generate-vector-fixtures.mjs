#!/usr/bin/env node
// scripts/reconciliation/generate-vector-fixtures.mjs
// 向量索引对账 fixture 生成器（Phase 2 任务 2.3「向量移植」）。
//
// 对账模式：同一 fixture 输入双跑（TS vitest ↔ Swift Testing）。
//
// Cut 5 / 5b-2a 删除了 CosineHnswIndex（生产侧零引用），5d-1 随之删掉本
// 生成器的 HNSW 参照实现与 fixture 的 hnsw 段：本脚本现在只产出
// CosineLshIndex（lsh-index.ts）的 fixture，对账对象是 Swift 侧
// Sources/GatherAnalysis/Face/VectorIndex.swift 的 Angular LSH。
//   - 语料：确定性合成 8 簇归一化高斯向量（构造照抄 hnsw-recall.test.ts
//     makeCenters/makeCorpus/makeQueries，DIM 参数化），行集 N=1000，
//     保留集查询 100 条（异种子，参照 hnsw-recall.test.ts:115-123）。
//     文件名里的 hnsw-recall 是语料来源的历史事实，与 HNSW 索引无关。
//   - LSH：参照实现照抄 lsh-index.ts 全类，unitVectors=true（同
//     face-clusterer-lsh.test.ts:234），复刻 measureNeighborRecall
//     （face-clusterer-lsh.test.ts:227-272）在 eps=0.6 下按相似度分桶的
//     邻域召回。
// 入库到 desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/
// Fixtures/vector-fixtures.json，Swift 侧 VectorIndexReconciliationTests
// 加载同一 JSON 逐 case 比对。
//
// 用法：
//   node scripts/reconciliation/generate-vector-fixtures.mjs            # 生成/覆盖 fixture
//   node scripts/reconciliation/generate-vector-fixtures.mjs --check    # 重算比对，漂移退出 1

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// 语料参数参照 hnsw-recall.test.ts（DIM 按 fixture 体积约束参数化为 128）。
const DIM = 128
const CLUSTERS = 8
const ADJACENT_CENTER_COSINES = [0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9]
const SIGMA = 0.03
// 同 hnsw-recall.test.ts:19 与 face-clusterer-lsh.test.ts:26
const SEED = 0x6a774c3
const QUERY_SEED = SEED ^ 0x13579bdf
const NUM_ROWS = 1000
const NUM_QUERIES = 100
// LSH 召回口径同 face-clusterer-lsh.test.ts（EPS/MIN 采样）
const LSH_EPS = 0.6
const LSH_SAMPLE = 100

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(SCRIPT_DIR, '..', '..')
const FIXTURE_PATH = path.join(
  ROOT,
  'desktop', 'native', 'gather-core',
  'Tests', 'GatherCoreTests', 'Reconciliation', 'Fixtures',
  'vector-fixtures.json',
)

// ─────────────────────────────────────────────────────────────────────────────
// 共用核心：PRNG 与点积（语料构造与 LSH 参照实现共用）
// ─────────────────────────────────────────────────────────────────────────────

// lsh-index.ts:62-71
function mulberry32(seed) {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// lsh-index.ts:92-112
function dotProduct(a, aOffset, b, bOffset, dim) {
  let dot = 0
  let k = 0
  for (; k + 4 <= dim; k += 4) {
    dot +=
      a[aOffset + k] * b[bOffset + k] +
      a[aOffset + k + 1] * b[bOffset + k + 1] +
      a[aOffset + k + 2] * b[bOffset + k + 2] +
      a[aOffset + k + 3] * b[bOffset + k + 3]
  }
  for (; k < dim; k++) {
    dot += a[aOffset + k] * b[bOffset + k]
  }
  return dot
}

// ─────────────────────────────────────────────────────────────────────────────
// 参照实现：CosineLshIndex —— 从 lsh-index.ts 照抄（仅去 TS 类型标注），
// 各函数行号指向 TS 源文件。核心循环逐字等价。
// ─────────────────────────────────────────────────────────────────────────────

// lsh-index.ts:40-46（与 DEFAULT_LSH_CONFIG 一致）
const DEFAULT_LSH_CONFIG = {
  bits: 16,
  tables: 6,
  probeRadius: 2,
  seed: 0xf4ce0b5e,
  unitVectors: false,
}

// lsh-index.ts:73-78
function gaussian(rand) {
  let u = 0
  do { u = rand() } while (u === 0)
  const v = rand()
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
}

// lsh-index.ts:81-90
function buildProbeMasks(bits, radius) {
  const masks = [0]
  for (let i = 0; i < bits; i++) masks.push(1 << i)
  if (radius >= 2) {
    for (let i = 0; i < bits; i++) {
      for (let j = i + 1; j < bits; j++) masks.push((1 << i) | (1 << j))
    }
  }
  return masks
}

// lsh-index.ts:114-286（全类照抄）
class CosineLshIndex {
  constructor(dim, config = DEFAULT_LSH_CONFIG) {
    if (!Number.isInteger(dim) || dim <= 0) {
      throw new Error(`LSH dimension must be a positive integer, received ${dim}`)
    }
    if (!Number.isInteger(config.bits) || config.bits < 6 || config.bits > 22) {
      throw new Error(`LSH bits must be an integer in [6, 22], received ${config.bits}`)
    }
    if (!Number.isInteger(config.tables) || config.tables < 1) {
      throw new Error(`LSH tables must be a positive integer, received ${config.tables}`)
    }
    if (!Number.isInteger(config.probeRadius) || config.probeRadius < 0 || config.probeRadius > 2) {
      throw new Error(`LSH probeRadius must be an integer in [0, 2], received ${config.probeRadius}`)
    }
    this.dim = dim
    this.config = config
    this.unitVectors = config.unitVectors ?? false
    this.probeMasks = buildProbeMasks(config.bits, config.probeRadius)

    this.planes = []
    for (let t = 0; t < config.tables; t++) {
      const rand = mulberry32((config.seed ^ Math.imul(t + 1, 0x9e3779b9)) >>> 0)
      const plane = new Float32Array(config.bits * dim)
      for (let i = 0; i < plane.length; i++) plane[i] = gaussian(rand)
      this.planes.push(plane)
    }
    this.count = 0
    this.rows = null
    this.starts = []
    this.members = []
    this.visited = new Uint32Array(0)
    this.candidateScratch = new Uint32Array(0)
    this.hitIndices = new Uint32Array(0)
    this.hitScores = new Float32Array(0)
    this.hits = { count: 0, indices: this.hitIndices, scores: this.hitScores }
    this.queryStamp = 1
  }

  get size() {
    return this.count
  }

  // lsh-index.ts:163-173
  hashRow(plane, row, rowOffset) {
    const dim = this.dim
    const bits = this.config.bits
    let hash = 0
    for (let k = 0; k < bits; k++) {
      const base = k * dim
      const dot = dotProduct(plane, base, row, rowOffset, dim)
      if (dot >= 0) hash |= 1 << k
    }
    return hash >>> 0
  }

  // lsh-index.ts:176-219
  build(rows, count) {
    if (rows.length !== count * this.dim) {
      throw new Error(
        `LSH build shape mismatch: ${count} rows of dim ${this.dim} needs ${count * this.dim} floats, received ${rows.length}`,
      )
    }
    this.count = count
    this.rows = rows
    this.visited = new Uint32Array(count)
    this.candidateScratch = new Uint32Array(count)
    this.hitIndices = new Uint32Array(count)
    this.hitScores = new Float32Array(count)
    this.hits = { count: 0, indices: this.hitIndices, scores: this.hitScores }
    this.queryStamp = 1
    const buckets = 1 << this.config.bits
    this.starts = []
    this.members = []
    for (let t = 0; t < this.config.tables; t++) {
      const plane = this.planes[t]
      const hashes = new Uint32Array(count)
      for (let i = 0; i < count; i++) hashes[i] = this.hashRow(plane, rows, i * this.dim)

      const counts = new Uint32Array(buckets)
      for (let i = 0; i < count; i++) counts[hashes[i]]++

      const starts = new Uint32Array(buckets + 1)
      let acc = 0
      for (let b = 0; b < buckets; b++) {
        starts[b] = acc
        acc += counts[b]
      }
      starts[buckets] = acc

      const members = new Uint32Array(count)
      const cursor = new Uint32Array(buckets)
      for (let b = 0; b < buckets; b++) cursor[b] = starts[b]
      for (let i = 0; i < count; i++) {
        const bucket = hashes[i]
        members[cursor[bucket]++] = i
      }
      this.starts.push(starts)
      this.members.push(members)
    }
  }

  // lsh-index.ts:229-285
  neighbors(query, queryOffset, threshold) {
    if (this.count === 0) {
      this.hits.count = 0
      return this.hits
    }
    if (query.length - queryOffset < this.dim) {
      throw new Error(
        `LSH query shape mismatch: expected dim ${this.dim}, received ${query.length - queryOffset} floats`,
      )
    }
    const rows = this.rows
    if (!rows) throw new Error('LSH index has no rows; call build() first')

    const stamp = this.queryStamp++
    if (stamp === 0) {
      this.visited.fill(0)
      this.queryStamp = 1
    }

    const candidates = this.candidateScratch
    let candidateCount = 0
    for (let t = 0; t < this.config.tables; t++) {
      const hash = this.hashRow(this.planes[t], query, queryOffset)
      const starts = this.starts[t]
      const members = this.members[t]
      for (let m = 0; m < this.probeMasks.length; m++) {
        const bucket = hash ^ this.probeMasks[m]
        const from = starts[bucket]
        const to = starts[bucket + 1]
        for (let p = from; p < to; p++) {
          const candidate = members[p]
          if (this.visited[candidate] === stamp) continue
          this.visited[candidate] = stamp
          candidates[candidateCount++] = candidate
        }
      }
    }
    candidates.subarray(0, candidateCount).sort()

    this.hits.count = verifyCandidates(
      query,
      queryOffset,
      rows,
      this.dim,
      threshold,
      this.unitVectors,
      candidates,
      candidateCount,
      this.hitIndices,
      this.hitScores,
    )
    return this.hits
  }
}

// lsh-index.ts:291-344
function verifyCandidates(
  query,
  queryOffset,
  rows,
  dim,
  threshold,
  unitVectors,
  candidates,
  candidateCount,
  hitIndices,
  hitScores,
) {
  let hitCount = 0
  for (let c = 0; c < candidateCount; c++) {
    const candidate = candidates[c]
    const rowOffset = candidate * dim
    let score
    if (unitVectors) {
      score = dotProduct(query, queryOffset, rows, rowOffset, dim)
      if (score < threshold) continue
    } else {
      let dot = 0
      let magQ = 0
      let magR = 0
      let k = 0
      for (; k + 4 <= dim; k += 4) {
        const q0 = query[queryOffset + k]
        const q1 = query[queryOffset + k + 1]
        const q2 = query[queryOffset + k + 2]
        const q3 = query[queryOffset + k + 3]
        const r0 = rows[rowOffset + k]
        const r1 = rows[rowOffset + k + 1]
        const r2 = rows[rowOffset + k + 2]
        const r3 = rows[rowOffset + k + 3]
        dot += q0 * r0 + q1 * r1 + q2 * r2 + q3 * r3
        magQ += q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3
        magR += r0 * r0 + r1 * r1 + r2 * r2 + r3 * r3
      }
      for (; k < dim; k++) {
        const q = query[queryOffset + k]
        const r = rows[rowOffset + k]
        dot += q * r
        magQ += q * q
        magR += r * r
      }
      if (magQ === 0 || magR === 0) continue
      score = dot / (Math.sqrt(magQ) * Math.sqrt(magR))
      if (score < threshold) continue
    }
    hitIndices[hitCount] = candidate
    hitScores[hitCount] = score
    hitCount++
  }
  return hitCount
}

// ─────────────────────────────────────────────────────────────────────────────
// 语料构造：照抄 hnsw-recall.test.ts（15-123 行），DIM 参数化。
// 全部语料（索引行与保留集查询）共享同一组中心，查询来自异种子
// （hnsw-recall.test.ts:115-123 注释：衡量保留集召回而非自召回）。
// ─────────────────────────────────────────────────────────────────────────────

// hnsw-recall.test.ts:32-39
function makeGaussian(rand) {
  return () => {
    let u = 0
    do { u = rand() } while (u === 0)
    const v = rand()
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
  }
}

// hnsw-recall.test.ts:41-72
function makeCenters(gauss) {
  const centers = []
  const c1 = new Float64Array(DIM)
  c1[0] = 1
  centers.push(c1)
  for (let i = 1; i < CLUSTERS; i++) {
    const v = new Float64Array(DIM)
    let norm = 0
    for (let k = 0; k < DIM; k++) { v[k] = gauss(); norm += v[k] * v[k] }
    norm = Math.sqrt(norm)
    for (let k = 0; k < DIM; k++) v[k] /= norm
    for (const previous of centers) {
      let proj = 0
      for (let k = 0; k < DIM; k++) proj += v[k] * previous[k]
      for (let k = 0; k < DIM; k++) v[k] -= proj * previous[k]
    }
    norm = 0
    for (let k = 0; k < DIM; k++) norm += v[k] * v[k]
    norm = Math.sqrt(norm)
    for (let k = 0; k < DIM; k++) v[k] /= norm

    const target = ADJACENT_CENTER_COSINES[i - 1]
    const alpha = target / Math.sqrt(1 - target * target)
    const w = new Float64Array(DIM)
    let wnorm = 0
    for (let k = 0; k < DIM; k++) { w[k] = v[k] + alpha * centers[i - 1][k]; wnorm += w[k] * w[k] }
    wnorm = Math.sqrt(wnorm)
    for (let k = 0; k < DIM; k++) w[k] /= wnorm
    centers.push(w)
  }
  return centers
}

// hnsw-recall.test.ts:79 —— 所有语料共享 ONE 组中心
const CENTERS = makeCenters(makeGaussian(mulberry32(SEED)))

// hnsw-recall.test.ts:81-99
function makeCorpus(count, seed) {
  const rand = mulberry32(seed)
  const gauss = makeGaussian(rand)
  const rows = []
  for (let i = 0; i < count; i++) {
    const center = CENTERS[i % CLUSTERS]
    const row = new Float32Array(DIM)
    for (let k = 0; k < DIM; k++) {
      row[k] = center[k] + gauss() * SIGMA
    }
    let norm = 0
    for (let k = 0; k < DIM; k++) norm += row[k] * row[k]
    norm = Math.sqrt(norm)
    for (let k = 0; k < DIM; k++) row[k] /= norm
    rows.push(row)
  }
  return rows
}

// hnsw-recall.test.ts:121-123
function makeQueries(count) {
  return makeCorpus(count, QUERY_SEED)
}

// ─────────────────────────────────────────────────────────────────────────────
// LSH 邻域召回测量：照抄 face-clusterer-lsh.test.ts:200-272。
// ─────────────────────────────────────────────────────────────────────────────

// face-clusterer-lsh.test.ts:200-225
function exactNeighbors(flat, n, dim, pointIndex, eps) {
  const result = []
  const pointOffset = pointIndex * dim
  for (let i = 0; i < n; i++) {
    if (i === pointIndex) continue
    let dot = 0
    let k = 0
    const rowOffset = i * dim
    for (; k + 4 <= dim; k += 4) {
      dot +=
        flat[pointOffset + k] * flat[rowOffset + k] +
        flat[pointOffset + k + 1] * flat[rowOffset + k + 1] +
        flat[pointOffset + k + 2] * flat[rowOffset + k + 2] +
        flat[pointOffset + k + 3] * flat[rowOffset + k + 3]
    }
    for (; k < dim; k++) dot += flat[pointOffset + k] * flat[rowOffset + k]
    if (dot >= eps) result.push({ index: i, score: dot })
  }
  return result
}

// face-clusterer-lsh.test.ts:227-272（index 由调用方构造）
function measureNeighborRecall(flat, n, dim, eps, sampleSize, index) {
  const buckets = [
    { min: eps, max: 0.65 },
    { min: 0.65, max: 0.7 },
    { min: 0.7, max: 0.8 },
    { min: 0.8, max: 0.9 },
    { min: 0.9, max: 1.01 },
  ]
  const stats = buckets.map(bucket => ({ ...bucket, recalled: 0, total: 0 }))
  let recallTotal = 0
  let pairsTotal = 0
  for (let s = 0; s < sampleSize; s++) {
    const pointIndex = Math.floor((s * 7919) % n)
    const exact = exactNeighbors(flat, n, dim, pointIndex, eps)
    const hits = index.neighbors(flat, pointIndex * dim, eps)
    const lshSet = new Set()
    for (let h = 0; h < hits.count; h++) {
      if (hits.indices[h] !== pointIndex) lshSet.add(hits.indices[h])
    }
    for (const neighbor of exact) {
      const bucket = stats.findIndex(b => neighbor.score >= b.min && neighbor.score < b.max)
      if (bucket < 0) continue
      stats[bucket].total++
      if (lshSet.has(neighbor.index)) stats[bucket].recalled++
      pairsTotal++
      recallTotal += lshSet.has(neighbor.index) ? 1 : 0
    }
  }
  return {
    perBucket: stats.map(({ min, max, recalled, total }) => ({
      range: `[${min}, ${max})`,
      recall: total > 0 ? recalled / total : 1,
      pairs: total,
    })),
    total: pairsTotal > 0 ? recallTotal / pairsTotal : 1,
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 组装与校验
// ─────────────────────────────────────────────────────────────────────────────

function buildFixture() {
  const rows = makeCorpus(NUM_ROWS)
  const queries = makeQueries(NUM_QUERIES)

  const flat = new Float32Array(NUM_ROWS * DIM)
  for (let i = 0; i < NUM_ROWS; i++) flat.set(rows[i], i * DIM)
  const queryFlat = new Float32Array(NUM_QUERIES * DIM)
  for (let q = 0; q < NUM_QUERIES; q++) queryFlat.set(queries[q], q * DIM)

  // LSH：建桶 + eps 邻域召回（unitVectors=true，同 face-clusterer-lsh.test.ts:234）
  const lshIndex = new CosineLshIndex(DIM, { ...DEFAULT_LSH_CONFIG, unitVectors: true })
  lshIndex.build(flat, NUM_ROWS)
  const recall = measureNeighborRecall(flat, NUM_ROWS, DIM, LSH_EPS, LSH_SAMPLE, lshIndex)

  if (!(recall.total > 0.5)) {
    throw new Error(`fatal: LSH 总召回 ${recall.total} <= 0.5，fixture 语料失效`)
  }
  for (const bucket of recall.perBucket) {
    if (bucket.pairs > 0 && !(bucket.recall > 0.4)) {
      throw new Error(`fatal: LSH 分桶召回 ${bucket.range}=${bucket.recall} <= 0.4（${bucket.pairs} pairs）`)
    }
  }

  return {
    seed: SEED,
    source: 'desktop/src/main/services/face-kw/lsh-index.ts（语料参照 hnsw-recall.test.ts）',
    dim: DIM,
    clusters: CLUSTERS,
    sigma: SIGMA,
    numRows: NUM_ROWS,
    numQueries: NUM_QUERIES,
    querySeed: QUERY_SEED,
    lsh: {
      config: { ...DEFAULT_LSH_CONFIG, unitVectors: true },
      eps: LSH_EPS,
      sampleSize: LSH_SAMPLE,
      recall,
    },
    rows: Array.from(flat),
    queries: Array.from(queryFlat),
  }
}

function main() {
  const check = process.argv.includes('--check')

  const fixture = buildFixture()
  const json = JSON.stringify(fixture, null, 2) + '\n'
  const bytes = Buffer.byteLength(json, 'utf8')

  if (check) {
    if (!fs.existsSync(FIXTURE_PATH)) {
      console.error(`--check 失败：fixture 不存在 ${FIXTURE_PATH}（先运行生成模式）`)
      process.exit(1)
    }
    const existing = fs.readFileSync(FIXTURE_PATH, 'utf8')
    if (existing !== json) {
      console.error(
        `--check 失败：fixture 漂移（seed=${SEED}, ${fixture.numRows} rows, ${fixture.numQueries} queries）\n` +
          `现有文件：${FIXTURE_PATH}\n请重新生成并提交。`,
      )
      process.exit(1)
    }
    console.log(
      `OK: ${fixture.numRows} rows × ${fixture.dim} dim + ${fixture.numQueries} queries 与 ${FIXTURE_PATH} 完全一致 ` +
        `（seed=${SEED}, ${(bytes / 1024 / 1024).toFixed(2)} MB, LSH only）`,
    )
    return
  }

  fs.mkdirSync(path.dirname(FIXTURE_PATH), { recursive: true })
  fs.writeFileSync(FIXTURE_PATH, json)
  console.log(
    `已写入 ${FIXTURE_PATH}（seed=${SEED}, ${fixture.numRows} rows × ${fixture.dim} dim, ` +
      `${fixture.numQueries} queries, ${(bytes / 1024 / 1024).toFixed(2)} MB）\n` +
      `  LSH total recall=${fixture.lsh.recall.total.toFixed(4)} ` +
      fixture.lsh.recall.perBucket.map(b => `${b.range}: ${b.recall.toFixed(3)} (${b.pairs})`).join(' '),
  )
}

main()
