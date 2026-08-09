#!/usr/bin/env node
// scripts/reconciliation/generate-clusterer-fixtures.mjs
// Face Clusterer（face-clusterer.ts）对账 fixture 生成器。
// 参照实现：照抄 desktop/src/main/services/face-kw/face-clusterer.ts 的
// normalizeRows/rowDotProduct/exactRegionQuery/clusterEmbeddings（exact 路径，
// 行号 60-93/95-230 中 LSH 无关部分）。LSH 分支的正确性由 vector-fixtures
// 对账（CosineLshIndex recall 门）与 Swift 侧集成测试（LSH 启用时结果与
// exact 一致）共同保证。
// 用法：node generate-clusterer-fixtures.mjs [--check]
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import * as path from 'node:path'

const OUT = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..', '..', 'desktop', 'native', 'gather-core',
  'Tests', 'GatherCoreTests', 'Reconciliation', 'Fixtures', 'clusterer-fixtures.json')

// mulberry32（与 TS 测试同款 PRNG）
function mulberry32(seed) {
  let a = seed >>> 0
  return function () {
    a |= 0
    a = (a + 0x6D2B79F5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// ── 参照实现（face-clusterer.ts:39-93、147-169 照抄） ──
function rowDotProduct(flat, dim, aOffset, bOffset) {
  let dot = 0
  let k = 0
  for (; k + 4 <= dim; k += 4) {
    dot +=
      flat[aOffset + k] * flat[bOffset + k] +
      flat[aOffset + k + 1] * flat[bOffset + k + 1] +
      flat[aOffset + k + 2] * flat[bOffset + k + 2] +
      flat[aOffset + k + 3] * flat[bOffset + k + 3]
  }
  for (; k < dim; k++) {
    dot += flat[aOffset + k] * flat[bOffset + k]
  }
  return dot
}

function normalizeRows(flat, n, dim) {
  for (let i = 0; i < n; i++) {
    const offset = i * dim
    let sumSq = 0
    for (let k = 0; k < dim; k++) {
      const value = flat[offset + k]
      sumSq += value * value
    }
    const norm = Math.sqrt(sumSq)
    if (norm === 0) continue
    const invNorm = 1 / norm
    for (let k = 0; k < dim; k++) {
      flat[offset + k] *= invNorm
    }
  }
}

function exactRegionQuery(flat, n, dim, pointIndex, eps) {
  const neighbors = []
  const pointOffset = pointIndex * dim
  for (let i = 0; i < n; i++) {
    if (i === pointIndex) continue
    if (rowDotProduct(flat, dim, pointOffset, i * dim) >= eps) {
      neighbors.push(i)
    }
  }
  return neighbors
}

// exact 路径的 clusterEmbeddings（face-clusterer.ts:95-230 去掉 LSH 分支与进度）
function referenceCluster(entries, eps, minPts) {
  const n = entries.length
  if (n === 0) return { clusters: [], noise: [] }
  const dim = entries[0].embedding.length
  const flat = new Float32Array(n * dim)
  for (let i = 0; i < n; i++) {
    const source = entries[i].embedding
    if (source.length !== dim) {
      throw new Error(`Embedding dimension mismatch: expected ${dim}, received ${source.length}`)
    }
    flat.set(source, i * dim)
  }
  normalizeRows(flat, n, dim)

  const regionQuery = (pointIndex) => exactRegionQuery(flat, n, dim, pointIndex, eps)

  const visited = new Uint8Array(n)
  const assigned = new Uint8Array(n)
  const clusters = []
  const noiseIndices = []
  const minNeighbors = minPts - 1

  for (let i = 0; i < n; i++) {
    if (visited[i]) continue
    visited[i] = 1

    const neighbors = regionQuery(i)
    if (neighbors.length < minNeighbors) {
      noiseIndices.push(i)
      continue
    }

    const cluster = [entries[i]]
    assigned[i] = 1

    const seeds = neighbors
    const queued = new Uint8Array(n)
    for (const seed of neighbors) queued[seed] = 1
    let seedIdx = 0

    while (seedIdx < seeds.length) {
      const currentIdx = seeds[seedIdx]
      seedIdx++

      if (assigned[currentIdx]) continue

      if (!visited[currentIdx]) {
        visited[currentIdx] = 1
        const currentNeighbors = regionQuery(currentIdx)
        if (currentNeighbors.length >= minNeighbors) {
          for (const candidate of currentNeighbors) {
            if (!visited[candidate] && !queued[candidate]) {
              queued[candidate] = 1
              seeds.push(candidate)
            }
          }
        }
      }

      if (!assigned[currentIdx]) {
        assigned[currentIdx] = 1
        cluster.push(entries[currentIdx])
      }
    }

    clusters.push(cluster)
  }

  const noise = noiseIndices.filter((index) => !assigned[index]).map((index) => entries[index])
  return { clusters, noise }
}

// ── 语料构造 ──
// 簇中心（固定）生成：每个簇一个基向量 + 高斯扰动，保证确定性。
function gaussian(rand) {
  const u = Math.max(rand(), 1e-12)
  const v = rand()
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
}

// 生成簇语料：k 簇，每簇 size 行，dim 维。
// 中心为正交化基（正交基上做小扰动），簇内 cosine ≥ 0.95，簇间 ≤ 0.1。
function makeClusterCorpus(rand, dim, k, size, perturb) {
  // 正交基（Gram-Schmidt 于随机向量）
  const bases = []
  for (let c = 0; c < k; c++) {
    const v = []
    for (let d = 0; d < dim; d++) v.push(gaussian(rand))
    // 正交化
    for (const b of bases) {
      let dot = 0
      for (let d = 0; d < dim; d++) dot += v[d] * b[d]
      for (let d = 0; d < dim; d++) v[d] -= dot * b[d]
    }
    let norm = 0
    for (let d = 0; d < dim; d++) norm += v[d] * v[d]
    norm = Math.sqrt(norm)
    for (let d = 0; d < dim; d++) v[d] /= norm || 1
    bases.push(v)
  }
  const entries = []
  let obs = 1
  for (let c = 0; c < k; c++) {
    for (let s = 0; s < size; s++) {
      const e = []
      for (let d = 0; d < dim; d++) e.push(bases[c][d] + gaussian(rand) * perturb)
      entries.push({ observationId: obs++, photoId: `c${c}p${s}`, embedding: e })
    }
  }
  return entries
}

function makeNoiseEntry(rand, dim, obs) {
  const e = []
  for (let d = 0; d < dim; d++) e.push(gaussian(rand))
  return { observationId: obs, photoId: `noise-${obs}`, embedding: e }
}

function buildCases() {
  const cases = []
  const dim = 8

  // case 1：单簇（全同向量 → 余弦 1.0，eps=0.95 全在一簇）
  {
    const entries = []
    for (let i = 0; i < 6; i++) {
      entries.push({ observationId: i + 1, photoId: `same${i}`, embedding: [1, 0, 0, 0, 0, 0, 0, 0] })
    }
    cases.push({ name: 'single-cluster-identical', eps: 0.95, minPts: 2, entries })
  }

  // case 2：两簇 + 1 噪声点（扰动 0.05，簇内 ≥0.99；噪声远离）
  {
    const rand = mulberry32(0xC1A0)
    const entries = makeClusterCorpus(rand, dim, 2, 5, 0.05)
    entries.push(makeNoiseEntry(rand, dim, 11))
    cases.push({ name: 'two-clusters-plus-noise', eps: 0.95, minPts: 2, entries })
  }

  // case 3：三簇（扰动 0.02，eps=0.98）
  {
    const rand = mulberry32(0xC1A1)
    const entries = makeClusterCorpus(rand, dim, 3, 4, 0.02)
    cases.push({ name: 'three-clusters', eps: 0.98, minPts: 2, entries })
  }

  // case 4：链式连接（A≈B、B≈C、A≉C → eps 下合成一簇）
  {
    const entries = [
      { observationId: 1, photoId: 'a', embedding: [1, 0, 0, 0, 0, 0, 0, 0] },
      { observationId: 2, photoId: 'b', embedding: [0.99, 0.141, 0, 0, 0, 0, 0, 0] },
      { observationId: 3, photoId: 'c', embedding: [0.98, 0.199, 0, 0, 0, 0, 0, 0] },
      { observationId: 4, photoId: 'd', embedding: [0, 1, 0, 0, 0, 0, 0, 0] },
    ]
    cases.push({ name: 'chain-connection', eps: 0.99, minPts: 2, entries })
  }

  // case 5：空输入
  cases.push({ name: 'empty', eps: 0.9, minPts: 2, entries: [] })

  // case 6：全分散 → 全 noise
  {
    const rand = mulberry32(0xC1A2)
    const entries = []
    for (let i = 0; i < 5; i++) entries.push(makeNoiseEntry(rand, dim, i + 1))
    cases.push({ name: 'all-scattered', eps: 0.95, minPts: 3, entries })
  }

  // case 7：minPts=1 → 每点自成簇（minNeighbors=0，空邻居也成簇）
  {
    const entries = [
      { observationId: 1, photoId: 'a', embedding: [1, 0, 0, 0, 0, 0, 0, 0] },
      { observationId: 2, photoId: 'b', embedding: [0, 1, 0, 0, 0, 0, 0, 0] },
    ]
    cases.push({ name: 'minpts-one-singletons', eps: 0.95, minPts: 1, entries })
  }

  // case 8：零向量（norm=0 跳过归一化 → 与任何向量点积 0，全 noise）
  {
    const entries = [
      { observationId: 1, photoId: 'zero', embedding: [0, 0, 0, 0, 0, 0, 0, 0] },
      { observationId: 2, photoId: 'unit', embedding: [1, 0, 0, 0, 0, 0, 0, 0] },
    ]
    cases.push({ name: 'zero-vector', eps: 0.9, minPts: 2, entries })
  }

  return cases
}

function serializeCases(cases) {
  return cases.map((c) => {
    const { clusters, noise } = referenceCluster(c.entries, c.eps, c.minPts)
    return {
      name: c.name,
      eps: c.eps,
      minPts: c.minPts,
      entries: c.entries.map((e) => ({
        observationId: e.observationId,
        photoId: e.photoId,
        embedding: e.embedding,
      })),
      expectedClusters: clusters.map((cl) => cl.map((e) => e.observationId)),
      expectedNoise: noise.map((e) => e.observationId),
    }
  })
}

const seed = 20260809
const cases = buildCases()
const fixture = { seed, cases: serializeCases(cases) }

if (process.argv.includes('--check')) {
  if (!existsSync(OUT)) {
    console.error(`fixture 不存在：${OUT}（先运行生成）`)
    process.exit(1)
  }
  const onDisk = JSON.parse(readFileSync(OUT, 'utf8'))
  const fresh = JSON.stringify(fixture)
  if (JSON.stringify(onDisk) !== fresh) {
    console.error('DRIFT: fixture 与生成器输出不一致，请重新生成并提交')
    process.exit(1)
  }
  console.log(`OK: ${fixture.cases.length} cases 与 ${OUT} 完全一致（seed=${seed}）`)
  process.exit(0)
}

writeFileSync(OUT, JSON.stringify(fixture, null, 2))
console.log(`written: ${OUT} (${fixture.cases.length} cases, ${Buffer.byteLength(JSON.stringify(fixture))} bytes)`)
