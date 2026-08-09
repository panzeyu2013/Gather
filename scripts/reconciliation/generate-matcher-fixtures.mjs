#!/usr/bin/env node
// scripts/reconciliation/generate-matcher-fixtures.mjs
// face-matcher 对账 fixture 生成器（Phase 2 任务 2.3「face-matcher 移植」）。
//
// 对账模式：同一 fixture 输入双跑（TS vitest ↔ Swift Testing）。
// 本生成器产出 FaceMatcher（face-matcher.ts）纯核心循环的 fixture：
//   - 参照实现 = face-matcher.ts 全类照抄（25-125 行，余弦 127-142 行），
//     底层 CosineLshIndex 照抄 lsh-index.ts（同 generate-vector-fixtures.mjs
//     内嵌副本，各函数行号指向 lsh-index.ts）。
//   - 语料构造参照 tests/unit/services/face-kw/face-matcher.test.ts：
//     * test-basis-lsh / test-basis-exact：dim 4 单位基向量 4 人物 + 4 查询
//       （test 的 ANN 块），lshMinPoints 分别取 1（> 4 触发 LSH）与 20_000
//       （精确扫描）——两路径结果必须一致（precision 恒等）。
//     * test-magnitude-exact：单行库 + 5 倍幅值查询（test 的 "exact cosine
//       semantics" 块）；注意 lshMinPoints=1 时 1 行 > 1 为假，TS 实际走的是
//       精确路径（test 注释 "Force the LSH branch" 与行为不符，按行为复刻）。
//     * empty-library：空库（test 首例）。
//     * synthetic-exact / synthetic-lsh：固定种子（mulberry32）合成簇语料
//       （构造同 generate-vector-fixtures.mjs，DIM=8 参数化）：12 行库 +
//       24 行库（lshMinPoints=8 超阈值 → LSH 路径），6 条查询含零向量、
//       库行精确副本（余弦恰 1.0）、反号行（远离全部簇）——覆盖命中/未命中
//       两分支与阈值边界。synthetic-lsh 附召回门：与暴力扫描逐查询比对
//       personId 一致比例 >= 0.95（任务门限）。
// 入库到 desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/
// Fixtures/matcher-fixtures.json，Swift 侧 MatcherReconciliationTests 加载
// 同一 JSON 逐 case 比对。
//
// 用法：
//   node scripts/reconciliation/generate-matcher-fixtures.mjs            # 生成/覆盖 fixture
//   node scripts/reconciliation/generate-matcher-fixtures.mjs --check    # 重算比对，漂移退出 1

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// ── 参数（语料参数按 fixture 体积约束参数化）──
const SYNT_DIM = 8
const SYNT_CLUSTERS = 4
const SYNT_SIGMA = 0.03
const SYNT_SEED = 0x8f1e2d3c
// lsh-index.ts:49
const LSH_MIN_POINTS = 20_000

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(SCRIPT_DIR, '..', '..')
const FIXTURE_PATH = path.join(
  ROOT,
  'desktop', 'native', 'gather-core',
  'Tests', 'GatherCoreTests', 'Reconciliation', 'Fixtures',
  'matcher-fixtures.json',
)

// ─────────────────────────────────────────────────────────────────────────────
// 参照实现 ①：CosineLshIndex —— 从 lsh-index.ts 照抄（同
// generate-vector-fixtures.mjs 副本；仅去 TS 类型标注）。
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

// lsh-index.ts:40-46（与 DEFAULT_LSH_CONFIG 一致；unitVectors=false）
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

// lsh-index.ts:114-286（全类照抄，仅保留匹配路径需要的公开方法）
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

  // lsh-index.ts:229-285（neighbors：桶并集 + 精确余弦重验）
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
// 参照实现 ②：FaceMatcher —— 从 face-matcher.ts 全类照抄（仅去 TS 类型标注、
// 追加生成器专用 fakePersonRepo；各函数行号指向 TS 源文件）。
// ─────────────────────────────────────────────────────────────────────────────

// face-matcher.ts:25-34（构造 + 私有库缓存字段）
class FaceMatcher {
  constructor(personRepo, lshMinPoints = LSH_MIN_POINTS) {
    this.personRepo = personRepo
    this.lshMinPoints = lshMinPoints
    this.libraryEmbeddings = null
    this.libraryFlat = null
    this.lshIndex = null
    this.libraryDim = 0
  }

  // face-matcher.ts:36-55（loadLibrary）
  loadLibrary() {
    if (this.libraryEmbeddings) return this.libraryEmbeddings
    const rows = this.personRepo.getAllEmbeddings()
    const embeddings = rows.map((r) => ({
      personId: r.person_id,
      embedding: new Float32Array(r.embedding.buffer, r.embedding.byteOffset, r.embedding.byteLength / 4),
    }))
    this.libraryEmbeddings = embeddings
    if (embeddings.length > this.lshMinPoints) {
      this.libraryDim = embeddings[0].embedding.length
      const flat = new Float32Array(embeddings.length * this.libraryDim)
      for (let i = 0; i < embeddings.length; i++) {
        flat.set(embeddings[i].embedding, i * this.libraryDim)
      }
      this.libraryFlat = flat
      this.lshIndex = new CosineLshIndex(this.libraryDim)
      this.lshIndex.build(flat, embeddings.length)
    }
    return this.libraryEmbeddings
  }

  // face-matcher.ts:57-61（invalidateCache）
  invalidateCache() {
    this.libraryEmbeddings = null
    this.libraryFlat = null
    this.lshIndex = null
  }

  // face-matcher.ts:63-124（matchAgainstLibrary）
  matchAgainstLibrary(embeddings, threshold) {
    const library = this.loadLibrary()
    const matched = new Map()
    const unmatched = []

    if (library.length === 0) {
      for (let i = 0; i < embeddings.length; i++) {
        unmatched.push(i)
      }
      return { matched, unmatched }
    }

    if (this.lshIndex && this.libraryFlat) {
      for (let i = 0; i < embeddings.length; i++) {
        const inputEmb = embeddings[i]
        if (inputEmb.length !== this.libraryDim) {
          throw new Error(`Vector length mismatch: ${inputEmb.length} vs ${this.libraryDim}`)
        }
        const hits = this.lshIndex.neighbors(inputEmb, 0, threshold)
        let bestIndex = -1
        let bestScore = 0
        for (let h = 0; h < hits.count; h++) {
          const score = hits.scores[h]
          if (score > bestScore) {
            bestScore = score
            bestIndex = hits.indices[h]
          }
        }
        if (bestIndex >= 0) {
          matched.set(i, { personId: library[bestIndex].personId, confidence: bestScore })
        } else {
          unmatched.push(i)
        }
      }
      return { matched, unmatched }
    }

    for (let i = 0; i < embeddings.length; i++) {
      const inputEmb = embeddings[i]
      let bestPersonId = ''
      let bestScore = 0

      for (let j = 0; j < library.length; j++) {
        const score = cosineSimilarity(inputEmb, library[j].embedding)
        if (score > bestScore) {
          bestScore = score
          bestPersonId = library[j].personId
        }
      }

      if (bestScore >= threshold && bestPersonId) {
        matched.set(i, { personId: bestPersonId, confidence: bestScore })
      } else {
        unmatched.push(i)
      }
    }

    return { matched, unmatched }
  }
}

// face-matcher.ts:127-142（cosineSimilarity）
function cosineSimilarity(a, b) {
  if (a.length !== b.length) {
    throw new Error(`Vector length mismatch: ${a.length} vs ${b.length}`)
  }
  const len = a.length
  let dot = 0
  let magA = 0
  let magB = 0
  for (let i = 0; i < len; i++) {
    dot += a[i] * b[i]
    magA += a[i] * a[i]
    magB += b[i] * b[i]
  }
  if (magA === 0 || magB === 0) return 0
  return dot / (Math.sqrt(magA) * Math.sqrt(magB))
}

// 生成器专用：模拟 TS 测试的 mockPersonRepo（tests/unit/services/face-kw/
// face-matcher.test.ts:5-8 / 20-24 / 38-42：Buffer.from(e.buffer)）
function fakePersonRepo(rows) {
  return {
    getAllEmbeddings: () =>
      rows.map((r) => ({
        person_id: r.personId,
        embedding: Buffer.from(r.embedding.buffer),
      })),
  }
}

function runReference(library, queries, threshold, lshMinPoints) {
  const matcher = new FaceMatcher(fakePersonRepo(library), lshMinPoints)
  const result = matcher.matchAgainstLibrary(queries, threshold)
  const matched = {}
  for (const [idx, m] of result.matched) {
    matched[String(idx)] = { personId: m.personId, confidence: m.confidence }
  }
  return { matched, unmatched: Array.from(result.unmatched) }
}

// ─────────────────────────────────────────────────────────────────────────────
// 语料构造：synthetic 用例参照 generate-vector-fixtures.mjs（构造源自
// hnsw-recall.test.ts:41-99），DIM/簇数参数化。
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

// hnsw-recall.test.ts:41-72（DIM/簇数/相邻中心余弦参数化）
function makeCenters(gauss, dim, clusters) {
  const adjacentCosines = [0.6, 0.65, 0.7]
  const centers = []
  const c1 = new Float64Array(dim)
  c1[0] = 1
  centers.push(c1)
  for (let i = 1; i < clusters; i++) {
    const v = new Float64Array(dim)
    let norm = 0
    for (let k = 0; k < dim; k++) { v[k] = gauss(); norm += v[k] * v[k] }
    norm = Math.sqrt(norm)
    for (let k = 0; k < dim; k++) v[k] /= norm
    for (const previous of centers) {
      let proj = 0
      for (let k = 0; k < dim; k++) proj += v[k] * previous[k]
      for (let k = 0; k < dim; k++) v[k] -= proj * previous[k]
    }
    norm = 0
    for (let k = 0; k < dim; k++) norm += v[k] * v[k]
    norm = Math.sqrt(norm)
    for (let k = 0; k < dim; k++) v[k] /= norm

    const target = adjacentCosines[i - 1]
    const alpha = target / Math.sqrt(1 - target * target)
    const w = new Float64Array(dim)
    let wnorm = 0
    for (let k = 0; k < dim; k++) { w[k] = v[k] + alpha * centers[i - 1][k]; wnorm += w[k] * w[k] }
    wnorm = Math.sqrt(wnorm)
    for (let k = 0; k < dim; k++) w[k] /= wnorm
    centers.push(w)
  }
  return centers
}

// hnsw-recall.test.ts:81-99（DIM/种子参数化；行归一化为单位向量）
function makeCorpus(count, seed, centers, dim, sigma) {
  const rand = mulberry32(seed)
  const gauss = makeGaussian(rand)
  const rows = []
  for (let i = 0; i < count; i++) {
    const center = centers[i % centers.length]
    const row = new Float32Array(dim)
    for (let k = 0; k < dim; k++) {
      row[k] = center[k] + gauss() * sigma
    }
    let norm = 0
    for (let k = 0; k < dim; k++) norm += row[k] * row[k]
    norm = Math.sqrt(norm)
    for (let k = 0; k < dim; k++) row[k] /= norm
    rows.push(row)
  }
  return rows
}

// ─────────────────────────────────────────────────────────────────────────────
// 用例组装与校验
// ─────────────────────────────────────────────────────────────────────────────

function makeCase(name, library, queries, threshold, lshMinPoints) {
  const ref = runReference(library, queries, threshold, lshMinPoints)
  return {
    name,
    path: library.length > lshMinPoints ? 'lsh' : 'exact',
    lshMinPoints,
    threshold,
    dim: library.length > 0 ? library[0].embedding.length : 0,
    library: library.map((r) => ({ personId: r.personId, embedding: Array.from(r.embedding) })),
    queries: queries.map((q) => Array.from(q)),
    expected: ref,
  }
}

function sameMatch(a, b) {
  return a.personId === b.personId && Math.abs(a.confidence - b.confidence) < 1e-4
}

function buildFixture() {
  const cases = []

  // ── ① face-matcher.test.ts 复刻（dim 4 单位基向量，test:47-77 语料）──
  const basisLibrary = [
    new Float32Array([1, 0, 0, 0]),
    new Float32Array([0, 1, 0, 0]),
    new Float32Array([0, 0, 1, 0]),
    new Float32Array([0, 0, 0, 1]),
  ].map((e, i) => ({ personId: `p${i + 1}`, embedding: e }))
  const basisQueries = [
    new Float32Array([0.99, 0.02, 0, 0]),
    new Float32Array([0.01, 0.98, 0.01, 0]),
    new Float32Array([0.05, 0.02, 0.9, 0.1]),
    new Float32Array([0.3, 0.3, 0.3, 0.3]),
  ]
  // test:62-67（lshMinPoints=1 强制 LSH 分支）
  cases.push(makeCase('test-basis-lsh', basisLibrary, basisQueries, 0.85, 1))
  // 同语料走精确扫描（默认阈值），两路径结果必须一致（precision 恒等）
  cases.push(makeCase('test-basis-exact', basisLibrary, basisQueries, 0.85, LSH_MIN_POINTS))
  // test:70-77（非单位查询：5 倍幅值；lshMinPoints=1 时 1 行 > 1 为假，实际走
  // 精确路径——按行为复刻，path 为 exact）
  cases.push(makeCase('test-magnitude-exact', [
    { personId: 'p1', embedding: new Float32Array([1, 0, 0, 0]) },
  ], [new Float32Array([5, 0, 0, 0])], 0.99, 1))

  // ── ② 空库（test:4-14）──
  cases.push(makeCase('empty-library', [], [
    new Float32Array([0.1, 0.2, 0.3]),
    new Float32Array([0.4, 0.5, 0.6]),
    new Float32Array([0.7, 0.8, 0.9]),
  ], 0.5, LSH_MIN_POINTS))

  // ── ③ synthetic：固定种子合成簇语料（dim 8，4 簇）──
  const centers = makeCenters(makeGaussian(mulberry32(SYNT_SEED)), SYNT_DIM, SYNT_CLUSTERS)
  const rows12 = makeCorpus(12, SYNT_SEED ^ 0x11111111, centers, SYNT_DIM, SYNT_SIGMA)
  const rows24 = makeCorpus(24, SYNT_SEED ^ 0x11111111, centers, SYNT_DIM, SYNT_SIGMA)
  const queries = makeCorpus(6, SYNT_SEED ^ 0x22222222, centers, SYNT_DIM, SYNT_SIGMA)
  queries[0] = new Float32Array(SYNT_DIM) // 零向量 → 余弦 0，必不命中
  queries[1] = new Float32Array(rows24[0]) // 与库行 0 逐位一致 → 余弦恰 1.0
  for (let k = 0; k < SYNT_DIM; k++) queries[2][k] = -queries[2][k] // 反号行 → 远离全部簇

  const exactCase = makeCase(
    'synthetic-exact', rows12.map((e, i) => ({ personId: `syn-${i}`, embedding: e })),
    queries, 0.65, LSH_MIN_POINTS)
  const lshCase = makeCase(
    'synthetic-lsh', rows24.map((e, i) => ({ personId: `syn-${i}`, embedding: e })),
    queries, 0.65, 8)
  cases.push(exactCase, lshCase)

  // ── 校验 ──
  // ① test-basis 两路径逐查询一致（precision 恒等；置信度差 < 1e-4）
  const basisLsh = cases.find((c) => c.name === 'test-basis-lsh')
  const basisExact = cases.find((c) => c.name === 'test-basis-exact')
  if (Object.keys(basisLsh.expected.matched).length !== Object.keys(basisExact.expected.matched).length
    || basisLsh.expected.unmatched.length !== basisExact.expected.unmatched.length) {
    throw new Error('fatal: test-basis 两路径匹配结构不一致')
  }
  for (const [key, v] of Object.entries(basisLsh.expected.matched)) {
    if (!sameMatch(basisExact.expected.matched[key], v)) {
      throw new Error(`fatal: test-basis 两路径 query ${key} 结果不一致`)
    }
  }
  if (basisLsh.expected.unmatched.some((i) => !basisExact.expected.unmatched.includes(i))) {
    throw new Error('fatal: test-basis 两路径 unmatched 不一致')
  }
  // ① 语义复刻：与 TS 测试断言一致（p1/p2/p3 命中，query 3 未命中）
  if (basisLsh.expected.matched['0']?.personId !== 'p1'
    || basisLsh.expected.matched['1']?.personId !== 'p2'
    || basisLsh.expected.matched['2']?.personId !== 'p3'
    || basisLsh.expected.matched['3'] !== undefined
    || basisLsh.expected.unmatched.length !== 1 || basisLsh.expected.unmatched[0] !== 3) {
    throw new Error('fatal: test-basis 结果与 face-matcher.test.ts 断言不符')
  }
  // ② 空库：全部 unmatched
  const empty = cases.find((c) => c.name === 'empty-library')
  if (Object.keys(empty.expected.matched).length !== 0 || empty.expected.unmatched.length !== 3) {
    throw new Error('fatal: empty-library 结果不符')
  }
  // ③ synthetic-exact：覆盖命中（>= 4 条，含 query 1 余弦恰 1.0）与未命中（>= 2 条）
  if (exactCase.expected.matched['1'] === undefined
    || Math.abs(exactCase.expected.matched['1'].confidence - 1.0) > 1e-6) {
    throw new Error('fatal: synthetic-exact query 1 未以余弦 1.0 命中')
  }
  if (Object.keys(exactCase.expected.matched).length < 4 || exactCase.expected.unmatched.length < 2) {
    throw new Error(
      `fatal: synthetic-exact 覆盖不足（matched=${Object.keys(exactCase.expected.matched).length}, unmatched=${exactCase.expected.unmatched.length}）`)
  }
  // ③ synthetic-lsh：precision 恒等 + 召回 >= 0.95（任务门限）+ 覆盖
  const brute = runReference(
    rows24.map((e, i) => ({ personId: `syn-${i}`, embedding: e })),
    queries, 0.65, Number.MAX_SAFE_INTEGER)
  for (const [key, v] of Object.entries(lshCase.expected.matched)) {
    if (!brute.matched[key] || brute.matched[key].personId !== v.personId) {
      throw new Error(`fatal: synthetic-lsh query ${key} 命中不在暴力结果中（precision 破坏）`)
    }
  }
  let agreed = 0
  let total = 0
  for (const [key, v] of Object.entries(brute.matched)) {
    total++
    if (lshCase.expected.matched[key]?.personId === v.personId) agreed++
  }
  const recall = total > 0 ? agreed / total : 1
  if (!(recall >= 0.95)) {
    throw new Error(`fatal: synthetic-lsh 召回 ${recall} < 0.95，语料失效`)
  }
  if (Object.keys(lshCase.expected.matched).length < 3 || lshCase.expected.unmatched.length < 1) {
    throw new Error(
      `fatal: synthetic-lsh 覆盖不足（matched=${Object.keys(lshCase.expected.matched).length}, unmatched=${lshCase.expected.unmatched.length}）`)
  }

  return {
    seed: SYNT_SEED,
    source: 'desktop/src/main/services/face-kw/face-matcher.ts（参照实现全类照抄；语料参照 tests/unit/services/face-kw/face-matcher.test.ts；LSH 底层参照 lsh-index.ts）',
    lshMinPointsDefault: LSH_MIN_POINTS,
    cases,
  }
}

function main() {
  const check = process.argv.includes('--check')

  const fixture = buildFixture()
  const json = JSON.stringify(fixture, null, 2) + '\n'
  const bytes = Buffer.byteLength(json, 'utf8')
  const summary = fixture.cases
    .map((c) => `${c.name}(${c.path}, ${c.library.length} rows × ${c.dim} dim, ${c.queries.length} queries)`)
    .join(', ')

  if (check) {
    if (!fs.existsSync(FIXTURE_PATH)) {
      console.error(`--check 失败：fixture 不存在 ${FIXTURE_PATH}（先运行生成模式）`)
      process.exit(1)
    }
    const existing = fs.readFileSync(FIXTURE_PATH, 'utf8')
    if (existing !== json) {
      console.error(
        `--check 失败：fixture 漂移（seed=${SYNT_SEED}）\n现有文件：${FIXTURE_PATH}\n请重新生成并提交。`,
      )
      process.exit(1)
    }
    console.log(`OK: ${summary} 与 ${FIXTURE_PATH} 完全一致（seed=${SYNT_SEED}, ${(bytes / 1024).toFixed(1)} KB）`)
    return
  }

  fs.mkdirSync(path.dirname(FIXTURE_PATH), { recursive: true })
  fs.writeFileSync(FIXTURE_PATH, json)
  console.log(
    `已写入 ${FIXTURE_PATH}（seed=${SYNT_SEED}, ${(bytes / 1024).toFixed(1)} KB）\n  ${summary}`,
  )
}

main()
