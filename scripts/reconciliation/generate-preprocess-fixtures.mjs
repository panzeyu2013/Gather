#!/usr/bin/env node
// scripts/reconciliation/generate-preprocess-fixtures.mjs
// Face 预处理对账 fixture 生成器（Phase 1 任务 1.5「对账测试框架」第二批）。
//
// 对账模式：同一 fixture 输入双跑（TS vitest ↔ Swift Testing）。
// 本生成器产出 face-kw 预处理纯核心循环 fixture，入库到
// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/Fixtures/
// preprocess-fixtures.json，Swift 侧 PreprocessReconciliationTests 加载同一
// JSON 逐 case 比对。输入取材自 tests/unit/services/face-kw/
// face-preprocessing.test.ts 的既有用例并扩展确定性样本。
//
// 覆盖三个纯函数：
//   1. resolveScrfdLayout            （face-detector.ts:118-134，布局解析）
//   2. estimateSimilarityTransform   （face-encoder.ts:76-113，五点相似变换）
//   3. alignedArcFaceInput           （face-encoder.ts:140-183 核心循环：
//                                      模板缩放 + 相似变换 + 双线性采样 + 归一化）
// 解码层（sharp/Buffer/onnx）不属于对账范围，输入直接用像素数组。
//
// 用法：
//   node scripts/reconciliation/generate-preprocess-fixtures.mjs            # 生成/覆盖 fixture
//   node scripts/reconciliation/generate-preprocess-fixtures.mjs --check    # 重算比对，漂移退出 1

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
  'preprocess-fixtures.json',
)

// ─────────────────────────────────────────────────────────────────────────────
// 参照实现：从 face-kw 源码照抄（仅去 TS 类型标注），行号指向 TS 源文件。
// 全部为纯函数，无第三方依赖；alignedArcFaceInput 的 data 参数以 Uint8Array
// 传入（TS 侧为 Buffer，索引语义一致）。
// ─────────────────────────────────────────────────────────────────────────────

// face-encoder.ts:68-74
const ARCFACE_TEMPLATE = [
  [38.2946, 51.6963],
  [73.5318, 51.5014],
  [56.0252, 71.7366],
  [41.5493, 92.3655],
  [70.7299, 92.2041],
]

// face-encoder.ts:76-113
function estimateSimilarityTransform(source, destination) {
  const sourceMean = source.reduce(
    (sum, point) => [sum[0] + point[0], sum[1] + point[1]],
    [0, 0],
  ).map((value) => value / source.length)
  const destinationMean = destination.reduce(
    (sum, point) => [sum[0] + point[0], sum[1] + point[1]],
    [0, 0],
  ).map((value) => value / destination.length)

  let denominator = 0
  let real = 0
  let imaginary = 0
  for (let index = 0; index < source.length; index++) {
    const sx = source[index][0] - sourceMean[0]
    const sy = source[index][1] - sourceMean[1]
    const dx = destination[index][0] - destinationMean[0]
    const dy = destination[index][1] - destinationMean[1]
    denominator += sx * sx + sy * sy
    real += sx * dx + sy * dy
    imaginary += sx * dy - sy * dx
  }
  if (denominator <= Number.EPSILON) {
    throw new Error('Face landmarks are degenerate')
  }

  const a = real / denominator
  const b = imaginary / denominator
  return {
    a,
    b,
    tx: destinationMean[0] - a * sourceMean[0] + b * sourceMean[1],
    ty: destinationMean[1] - b * sourceMean[0] - a * sourceMean[1],
  }
}

// face-encoder.ts:115-138
function sampleBilinear(data, width, height, channels, x, y, channel) {
  if (x < 0 || y < 0 || x > width - 1 || y > height - 1) return 0
  const x0 = Math.floor(x)
  const y0 = Math.floor(y)
  const x1 = Math.min(width - 1, x0 + 1)
  const y1 = Math.min(height - 1, y0 + 1)
  const wx = x - x0
  const wy = y - y0
  const at = (px, py) => data[(py * width + px) * channels + channel]
  return (
    at(x0, y0) * (1 - wx) * (1 - wy) +
    at(x1, y0) * wx * (1 - wy) +
    at(x0, y1) * (1 - wx) * wy +
    at(x1, y1) * wx * wy
  )
}

// face-encoder.ts:140-183（核心循环；sharp 解码层不在对账范围）
function alignedArcFaceInput(data, width, height, channels, landmarks, size) {
  const templateScale = size / 112
  const destination = ARCFACE_TEMPLATE.map(([x, y]) => [
    x * templateScale,
    y * templateScale,
  ])
  const transform = estimateSimilarityTransform(landmarks, destination)
  const determinant = transform.a * transform.a + transform.b * transform.b
  if (determinant <= Number.EPSILON) {
    throw new Error('Face alignment transform is singular')
  }

  const planeSize = size * size
  const input = new Float32Array(planeSize * 3)
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = x - transform.tx
      const dy = y - transform.ty
      const sourceX = (transform.a * dx + transform.b * dy) / determinant
      const sourceY = (-transform.b * dx + transform.a * dy) / determinant
      const destinationIndex = y * size + x
      for (let channel = 0; channel < 3; channel++) {
        const pixel = sampleBilinear(
          data,
          width,
          height,
          channels,
          sourceX,
          sourceY,
          channel,
        )
        input[channel * planeSize + destinationIndex] = (pixel - 127.5) / 127.5
      }
    }
  }
  return input
}

// face-detector.ts:118-134
function resolveScrfdLayout(outputCount) {
  if (outputCount === 6) {
    return { featureMaps: 3, strides: [8, 16, 32], anchorsPerCell: 2, hasLandmarks: false }
  }
  if (outputCount === 9) {
    return { featureMaps: 3, strides: [8, 16, 32], anchorsPerCell: 2, hasLandmarks: true }
  }
  if (outputCount === 10) {
    return { featureMaps: 5, strides: [8, 16, 32, 64, 128], anchorsPerCell: 1, hasLandmarks: false }
  }
  if (outputCount === 15) {
    return { featureMaps: 5, strides: [8, 16, 32, 64, 128], anchorsPerCell: 1, hasLandmarks: true }
  }
  throw new Error(
    `Unsupported SCRFD output signature: expected 6, 9, 10 or 15 tensors, received ${outputCount}`,
  )
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

function randomPixels(rand, length) {
  const pixels = new Array(length)
  for (let i = 0; i < length; i++) pixels[i] = Math.floor(rand() * 256)
  return pixels
}

function randomPoint(rand, min, max) {
  return [min + Math.floor(rand() * (max - min)), min + Math.floor(rand() * (max - min))]
}

function buildScrfdLayoutCases() {
  // face-preprocessing.test.ts:7-21 既有用例 + 6/10 布局扩展 + 报错扩展
  return [
    { name: 'layout-6', outputCount: 6 },
    { name: 'layout-9', outputCount: 9 },
    { name: 'layout-10', outputCount: 10 },
    { name: 'layout-15', outputCount: 15 },
    { name: 'layout-1-error', outputCount: 1 },
    { name: 'layout-7-error', outputCount: 7 },
  ].map((c) => {
    try {
      return { ...c, expected: resolveScrfdLayout(c.outputCount) }
    } catch (error) {
      return { ...c, error: error.message }
    }
  })
}

function buildTransformCases(rand) {
  const cases = []

  // face-preprocessing.test.ts:23-40 既有用例：仿射映射应被精确还原
  const source = [[10, 20], [30, 20], [20, 30], [12, 40], [28, 40]]
  const destination = source.map(([x, y]) => [
    x * 1.5 - y * 0.25 + 8,
    x * 0.25 + y * 1.5 - 3,
  ])
  cases.push({ name: 'affine-from-unit-test', source, destination })

  // 恒等：source === destination → a=1, b=0, tx=0, ty=0（逐位精确）
  const identityPoints = [[10, 20], [30, 20], [20, 30], [12, 40], [28, 40]]
  cases.push({ name: 'identity', source: identityPoints, destination: identityPoints })

  // 随机仿射 + 随机点集（确定性种子）
  for (let i = 0; i < 2; i++) {
    const src = Array.from({ length: 5 }, () => randomPoint(rand, 5, 100))
    const a = 0.6 + rand() * 0.8
    const b = -0.3 + rand() * 0.6
    const tx = -20 + rand() * 40
    const ty = -20 + rand() * 40
    const dest = src.map(([x, y]) => [
      a * x - b * y + tx,
      b * x + a * y + ty,
    ])
    cases.push({ name: `random-affine-${i + 1}`, source: src, destination: dest })
  }

  // 纯随机点对（非仿射变换 → 最小二乘相似变换）
  cases.push({ name: 'random-pair-1', source: Array.from({ length: 5 }, () => randomPoint(rand, 5, 100)), destination: Array.from({ length: 5 }, () => randomPoint(rand, 5, 100)) })

  // 退化：五点重合 → denominator ≈ 0
  const degenerate = [[20, 20], [20, 20], [20, 20], [20, 20], [20, 20]]
  cases.push({ name: 'degenerate', source: degenerate, destination: [[20, 20], [20, 20], [20, 20], [20, 20], [20, 20]] })

  return cases.map((c) => {
    try {
      const t = estimateSimilarityTransform(c.source, c.destination)
      return { ...c, expected: t }
    } catch (error) {
      return { ...c, error: error.message }
    }
  })
}

function buildAlignCases(rand) {
  const cases = []

  // 16x12 RGB：模板位置附近的五点（size=8）
  const imgA = randomPixels(rand, 16 * 12 * 3)
  cases.push({
    name: 'rgb16x12-template',
    width: 16,
    height: 12,
    channels: 3,
    pixels: imgA,
    landmarks: [[3.1, 3.8], [4.9, 3.8], [4.0, 5.2], [3.2, 6.4], [4.9, 6.4]],
    size: 8,
  })

  // 16x12 RGB：随机五点
  const imgB = randomPixels(rand, 16 * 12 * 3)
  cases.push({
    name: 'rgb16x12-random',
    width: 16,
    height: 12,
    channels: 3,
    pixels: imgB,
    landmarks: [randomPoint(rand, 1, 14), randomPoint(rand, 1, 14), randomPoint(rand, 1, 14), randomPoint(rand, 1, 14), randomPoint(rand, 1, 14)],
    size: 8,
  })

  // 12x12 均匀灰度（3 通道，gray 值复制三份）：size=16。
  // 注：TS 的 alignedArcFaceInput 对 channels<3 的输入会越界读出 undefined → NaN
  // （face-encoder.ts 的生产路径经 sharp removeAlpha 恒为 3 通道，不触发）；
  // NaN 无法入 JSON，故本 fixture 不用 channels<3，Swift 侧对 channels<3 抛错。
  const gray = randomPixels(rand, 12 * 12)
  const imgC = gray.flatMap((v) => [v, v, v])
  cases.push({
    name: 'gray12x12-c3',
    width: 12,
    height: 12,
    channels: 3,
    pixels: imgC,
    landmarks: [[4.5, 5.4], [7.0, 5.4], [5.8, 7.3], [4.6, 9.0], [6.9, 9.0]],
    size: 16,
  })

  // 8x8 RGB：五点挤在左上角 → 变换后源坐标大量越界 → 双线性采样返回 0
  const imgD = randomPixels(rand, 8 * 8 * 3)
  cases.push({
    name: 'rgb8x8-corner',
    width: 8,
    height: 8,
    channels: 3,
    pixels: imgD,
    landmarks: [[0.4, 0.4], [0.6, 0.4], [0.5, 0.6], [0.4, 0.8], [0.6, 0.8]],
    size: 8,
  })

  // 退化：五点重合 → 'Face landmarks are degenerate'
  const imgE = randomPixels(rand, 8 * 8 * 3)
  cases.push({
    name: 'degenerate-landmarks',
    width: 8,
    height: 8,
    channels: 3,
    pixels: imgE,
    landmarks: [[4, 4], [4, 4], [4, 4], [4, 4], [4, 4]],
    size: 8,
  })

  return cases.map((c) => {
    try {
      const input = alignedArcFaceInput(
        new Uint8Array(c.pixels),
        c.width,
        c.height,
        c.channels,
        c.landmarks,
        c.size,
      )
      return { ...c, expected: Array.from(input) }
    } catch (error) {
      return { ...c, error: error.message }
    }
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// 校验
// ─────────────────────────────────────────────────────────────────────────────

function validate() {
  const rand = mulberry32(SEED)
  const scrfdLayoutCases = buildScrfdLayoutCases()
  const transformCases = buildTransformCases(rand)
  const alignCases = buildAlignCases(rand)

  for (const c of scrfdLayoutCases) {
    if (c.expected === undefined && c.error === undefined) {
      throw new Error(`fatal: scrfd case ${c.name} 无 expected 也无 error`)
    }
  }
  for (const c of transformCases) {
    if (c.expected === undefined && c.error === undefined) {
      throw new Error(`fatal: transform case ${c.name} 无 expected 也无 error`)
    }
    if (c.expected !== undefined) {
      for (const key of ['a', 'b', 'tx', 'ty']) {
        if (!Number.isFinite(c.expected[key])) {
          throw new Error(`fatal: transform case ${c.name} ${key} 非有限值`)
        }
      }
    }
  }
  for (const c of alignCases) {
    if (c.expected === undefined && c.error === undefined) {
      throw new Error(`fatal: align case ${c.name} 无 expected 也无 error`)
    }
    if (c.pixels.length !== c.width * c.height * c.channels) {
      throw new Error(`fatal: align case ${c.name} 像素数与宽高通道不符`)
    }
    for (const p of c.pixels) {
      if (!Number.isInteger(p) || p < 0 || p > 255) {
        throw new Error(`fatal: align case ${c.name} 含非法像素 ${p}`)
      }
    }
    if (c.expected !== undefined) {
      if (c.expected.length !== c.size * c.size * 3) {
        throw new Error(`fatal: align case ${c.name} 输出长度不符`)
      }
      for (const v of c.expected) {
        if (!Number.isFinite(v)) throw new Error(`fatal: align case ${c.name} 含非有限输出`)
      }
    }
  }

  const byName = new Map(transformCases.map((c) => [c.name, c]))
  const affine = byName.get('affine-from-unit-test')
  const t = affine.expected
  if (Math.abs(t.a - 1.5) > 1e-9 || Math.abs(t.b - 0.25) > 1e-9) {
    throw new Error('fatal: affine-from-unit-test 未还原仿射变换')
  }
  const identity = byName.get('identity').expected
  if (identity.a !== 1 || identity.b !== 0 || identity.tx !== 0 || identity.ty !== 0) {
    throw new Error(`fatal: identity 非逐位精确: ${JSON.stringify(identity)}`)
  }
  const degenerate = byName.get('degenerate')
  if (degenerate.error !== 'Face landmarks are degenerate') {
    throw new Error('fatal: degenerate 期望抛错')
  }

  return { scrfdLayoutCases, transformCases, alignCases }
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

function main() {
  const check = process.argv.includes('--check')

  const { scrfdLayoutCases, transformCases, alignCases } = validate()
  const json = JSON.stringify({
    seed: SEED,
    source: 'desktop/src/main/services/face-kw/{face-detector,face-encoder}.ts',
    scrfdLayoutCases,
    transformCases,
    alignCases,
  }, null, 2) + '\n'

  if (check) {
    if (!fs.existsSync(FIXTURE_PATH)) {
      console.error(`--check 失败：fixture 不存在 ${FIXTURE_PATH}（先运行生成模式）`)
      process.exit(1)
    }
    const existing = fs.readFileSync(FIXTURE_PATH, 'utf8')
    if (existing !== json) {
      console.error(
        `--check 失败：fixture 漂移（seed=${SEED}, ${scrfdLayoutCases.length} scrfd + ${transformCases.length} transform + ${alignCases.length} align）\n` +
          `现有文件：${FIXTURE_PATH}\n请重新生成并提交。`,
      )
      process.exit(1)
    }
    console.log(`OK: ${scrfdLayoutCases.length} scrfd + ${transformCases.length} transform + ${alignCases.length} align 与 ${FIXTURE_PATH} 完全一致（seed=${SEED}）`)
    return
  }

  fs.mkdirSync(path.dirname(FIXTURE_PATH), { recursive: true })
  fs.writeFileSync(FIXTURE_PATH, json)
  console.log(`已写入 ${FIXTURE_PATH}（seed=${SEED}, ${scrfdLayoutCases.length} scrfd + ${transformCases.length} transform + ${alignCases.length} align）`)
}

main()
