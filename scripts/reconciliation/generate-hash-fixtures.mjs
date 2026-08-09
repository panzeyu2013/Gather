#!/usr/bin/env node
// scripts/reconciliation/generate-hash-fixtures.mjs
// dHash 对账 fixture 生成器（Phase 1 任务 1.5「对账测试框架」）。
//
// 对账模式：同一 fixture 输入双跑（TS vitest ↔ Swift XCTest/Swift Testing）。
// 本生成器产出 9x8 灰度像素网格 → 16 位 hex 的纯核心循环 fixture，
// 入库到 desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/Fixtures/，
// Swift 侧 DHashReconciliationTests 加载同一 JSON 逐 case 比对。
// （sharp resize/grayscale 属解码层，Phase 2.1 在 Swift 侧以 CoreImage 实现，不在本对账范围。）
//
// 用法：
//   node scripts/reconciliation/generate-hash-fixtures.mjs            # 生成/覆盖 fixture
//   node scripts/reconciliation/generate-hash-fixtures.mjs --check    # 重算比对，漂移退出 1

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const SEED = 42
const NUM_CASES = 50

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(SCRIPT_DIR, '..', '..')
const FIXTURE_PATH = path.join(
  ROOT,
  'desktop', 'native', 'gather-core',
  'Tests', 'GatherCoreTests', 'Reconciliation', 'Fixtures',
  'dhash-fixtures.json',
)

// 确定性伪随机（固定种子，保证 fixture 可复现）。
function mulberry32(seed) {
  let a = seed >>> 0
  return function () {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

// 以下循环逐字等价于 hash-computer.ts 第 14-27 行（computeDHash 核心循环），
// 仅将 Uint8Array 换成普通数组（值域 0-255，读写语义一致）。
// 来源：desktop/src/main/services/similarity/hash-computer.ts
function computeDHashHex(pixels) {
  let hash = 0n

  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const left = pixels[y * 9 + x]
      const right = pixels[y * 9 + x + 1]
      if (left < right) {
        hash |= 1n << BigInt(y * 8 + x)
      }
    }
  }

  return hash.toString(16).padStart(16, '0')
}

function randomGrid(rand) {
  const grid = new Array(9 * 8)
  for (let i = 0; i < grid.length; i++) {
    grid[i] = Math.floor(rand() * 256)
  }
  return grid
}

function buildGrid(index, rand) {
  // 固定索引覆盖边界情况，保证 fixture 中始终存在这些输入：
  if (index === 0) return new Array(72).fill(0) // 全零网格
  if (index === 1) return new Array(72).fill(255) // 全一网格
  if (index === 2) {
    // 重复行：8 行完全相同（同一随机行复制 8 次）
    const row = new Array(9)
    for (let i = 0; i < 9; i++) row[i] = Math.floor(rand() * 256)
    return Array.from({ length: 8 }, () => row).flat()
  }
  if (index === 3) {
    // 边界值混合：首/中/末像素强制 0 或 255
    const grid = randomGrid(rand)
    grid[0] = 255
    grid[35] = 0
    grid[36] = 255
    grid[71] = 0
    return grid
  }
  if (index === 4) return new Array(72).fill(128) // 相邻等值 → 严格比较全部不置位
  return randomGrid(rand)
}

function main() {
  const check = process.argv.includes('--check')

  const rand = mulberry32(SEED)
  const cases = []
  for (let i = 0; i < NUM_CASES; i++) {
    const pixels = buildGrid(i, rand)
    if (pixels.length !== 72) {
      console.error(`fatal: case ${i} 像素数 ${pixels.length} != 72`)
      process.exit(1)
    }
    for (const p of pixels) {
      if (!Number.isInteger(p) || p < 0 || p > 255) {
        console.error(`fatal: case ${i} 含非 0-255 像素值 ${p}`)
        process.exit(1)
      }
    }
    const expected = computeDHashHex(pixels)
    if (!/^[0-9a-f]{16}$/.test(expected)) {
      console.error(`fatal: case ${i} 非法 hex 输出 ${expected}`)
      process.exit(1)
    }
    cases.push({ pixels, expected })
  }

  const json = JSON.stringify({ seed: SEED, cases }, null, 2) + '\n'

  if (check) {
    if (!fs.existsSync(FIXTURE_PATH)) {
      console.error(`--check 失败：fixture 不存在 ${FIXTURE_PATH}（先运行生成模式）`)
      process.exit(1)
    }
    const existing = fs.readFileSync(FIXTURE_PATH, 'utf8')
    if (existing !== json) {
      console.error(
        `--check 失败：fixture 漂移（seed=${SEED}, ${NUM_CASES} cases）\n` +
          `现有文件：${FIXTURE_PATH}\n请重新生成并提交。`,
      )
      process.exit(1)
    }
    console.log(`OK: ${NUM_CASES} cases 与 ${FIXTURE_PATH} 完全一致（seed=${SEED}）`)
    return
  }

  fs.mkdirSync(path.dirname(FIXTURE_PATH), { recursive: true })
  fs.writeFileSync(FIXTURE_PATH, json)
  console.log(`已写入 ${FIXTURE_PATH}（seed=${SEED}, ${NUM_CASES} cases）`)
}

main()
