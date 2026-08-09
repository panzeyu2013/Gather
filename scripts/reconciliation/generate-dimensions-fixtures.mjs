#!/usr/bin/env node
// scripts/reconciliation/generate-dimensions-fixtures.mjs
// 图片尺寸对账 fixture 生成器（Phase 2 任务 2.1「解码 + 缩略图」）。
//
// 对账模式：同一 fixture 双跑（TS 参照实现 ↔ Swift 测试）。
// 本生成器以纯字节构造各格式最小合法样本（不依赖任何图像库），expected 手工
// 按格式规范算好写入下方 CASES；生成时与参照实现（fast-dimensions.ts 逐字
// 照抄，见下方 readDimensions）互验一致后才入库。Swift 侧
// DimensionsReconciliationTests 加载同一 JSON 逐 case 解码 base64 后比对。
//
// 用法：
//   node scripts/reconciliation/generate-dimensions-fixtures.mjs            # 生成/覆盖 fixture
//   node scripts/reconciliation/generate-dimensions-fixtures.mjs --check    # 重算比对，漂移退出 1

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(SCRIPT_DIR, '..', '..')
const FIXTURE_PATH = path.join(
  ROOT,
  'desktop', 'native', 'gather-core',
  'Tests', 'GatherCoreTests', 'Reconciliation', 'Fixtures',
  'dimensions-fixtures.json',
)

// ─────────────────────────────────────────────────────────────────────────────
// 参照实现：fast-dimensions.ts 逐字照抄（仅去 TS 类型标注）。
// 这是权威参照：expected 由下方构建函数构造的字节喂给本实现复算，
// 与手工期望值逐一对齐。
// ─────────────────────────────────────────────────────────────────────────────

function readDimensions(buf, ext) {
  if (buf.length < 12) return null

  const format = detectFormat(buf, ext)
  switch (format) {
    case 'jpeg': return readJpeg(buf)
    case 'png': return readPng(buf)
    case 'gif': return readGif(buf)
    case 'bmp': return readBmp(buf)
    case 'webp': return readWebp(buf)
    case 'tiff': return readTiff(buf)
    default: return null
  }
}

function detectFormat(buf, ext) {
  if (buf[0] === 0xFF && buf[1] === 0xD8) return 'jpeg'
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47) return 'png'
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) return 'gif'
  if (buf[0] === 0x42 && buf[1] === 0x4D) return 'bmp'
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46) {
    if (buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return 'webp'
  }
  if ((buf[0] === 0x49 && buf[1] === 0x49 && buf[2] === 0x2A && buf[3] === 0x00) ||
      (buf[0] === 0x4D && buf[1] === 0x4D && buf[2] === 0x00 && buf[3] === 0x2A)) return 'tiff'
  if (ext === '.tif' || ext === '.tiff') return 'tiff'
  return null
}

function readJpeg(buf) {
  for (let i = 0; i < buf.length - 5; i++) {
    if (buf[i] !== 0xFF) continue
    const marker = buf[i + 1]
    if (marker !== 0xC0 && marker !== 0xC1 && marker !== 0xC2) continue
    const length = buf.readUInt16BE(i + 2)
    if (length < 7 || i + 2 + length > buf.length) continue
    const h = buf.readUInt16BE(i + 5)
    const w = buf.readUInt16BE(i + 7)
    if (w > 0 && h > 0) return { width: w, height: h }
    i += 2 + length - 1
  }
  return null
}

function readPng(buf) {
  if (buf.length < 24) return null
  if (buf[12] !== 0x49 || buf[13] !== 0x48 || buf[14] !== 0x44 || buf[15] !== 0x52) return null
  const w = buf.readUInt32BE(16)
  const h = buf.readUInt32BE(20)
  if (w > 0 && h > 0) return { width: w, height: h }
  return null
}

function readGif(buf) {
  if (buf.length < 10) return null
  const w = buf.readUInt16LE(6)
  const h = buf.readUInt16LE(8)
  if (w > 0 && h > 0) return { width: w, height: h }
  return null
}

function readBmp(buf) {
  if (buf.length < 26) return null
  const w = buf.readInt32LE(18)
  const h = Math.abs(buf.readInt32LE(22))
  if (w > 0 && h > 0) return { width: w, height: h }
  return null
}

function readWebp(buf) {
  if (buf.length < 30) return null
  const chunkType = buf.toString('ascii', 12, 16)
  if (chunkType === 'VP8 ') {
    const w = buf.readUInt16LE(26) & 0x3FFF
    const h = buf.readUInt16LE(28) & 0x3FFF
    if (w > 0 && h > 0) return { width: w, height: h }
  } else if (chunkType === 'VP8L') {
    const bits = buf.readUInt32LE(21)
    const w = (bits & 0x3FFF) + 1
    const h = ((bits >> 14) & 0x3FFF) + 1
    if (w > 0 && h > 0) return { width: w, height: h }
  } else if (chunkType === 'VP8X') {
    if (buf.length < 24) return null
    const w = (buf.readUIntLE(18, 3) & 0xFFFFFF) + 1
    const h = (buf.readUIntLE(21, 3) & 0xFFFFFF) + 1
    if (w > 0 && h > 0) return { width: w, height: h }
  }
  return null
}

function readTiff(buf) {
  if (buf.length < 8) return null
  const isLE = buf[0] === 0x49
  const r16 = (o) => isLE ? buf.readUInt16LE(o) : buf.readUInt16BE(o)
  const r32 = (o) => isLE ? buf.readUInt32LE(o) : buf.readUInt32BE(o)

  let offset = r32(4)
  for (let ifd = 0; ifd < 4 && offset + 2 <= buf.length; ifd++) {
    const n = r16(offset)
    let w = 0, h = 0
    for (let i = 0; i < n && offset + 2 + (i + 1) * 12 <= buf.length; i++) {
      const eo = offset + 2 + i * 12
      const tag = r16(eo)
      const type = r16(eo + 2)
      const valOffset = eo + 8
      if (tag === 0x0100) w = type === 3 ? r16(valOffset) : r32(valOffset)
      if (tag === 0x0101) h = type === 3 ? r16(valOffset) : r32(valOffset)
    }
    if (w > 0 && h > 0) return { width: w, height: h }
    if (offset + 2 + n * 12 + 4 > buf.length) break
    offset = r32(offset + 2 + n * 12)
  }
  return null
}

// ─────────────────────────────────────────────────────────────────────────────
// 纯字节构造（最小合法样本；不依赖任何图像库）
// ─────────────────────────────────────────────────────────────────────────────

const ascii = (s) => Array.from(s, (ch) => ch.charCodeAt(0))
const u16le = (v) => [v & 0xFF, (v >>> 8) & 0xFF]
const u16be = (v) => [(v >>> 8) & 0xFF, v & 0xFF]
const u32le = (v) => [v & 0xFF, (v >>> 8) & 0xFF, (v >>> 16) & 0xFF, (v >>> 24) & 0xFF]
const u32be = (v) => [(v >>> 24) & 0xFF, (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF]
const u24le = (v) => [v & 0xFF, (v >>> 8) & 0xFF, (v >>> 16) & 0xFF]

// JPEG SOI + SOF 段：SOI(2) FF Cx | Lf(2)=11 | P(1)=8 | Y(2) | X(2) | Nf(1)=1 | 组件(3)
function jpegSof(marker, h, w) {
  return [
    0xFF, 0xD8,
    0xFF, marker, 0x00, 0x0B,
    0x08, ...u16be(h), ...u16be(w),
    0x01, 0x22, 0x00, 0x00,
  ]
}

// PNG 签名 + IHDR 块：len(4)=13 | "IHDR" | w(4) | h(4) | 5 个深度/类型字节 | CRC(4)
function pngIhdr(w, h) {
  return [
    ...ascii('\x89PNG\r\n\x1a\n'),
    ...u32be(13), ...ascii('IHDR'),
    ...u32be(w), ...u32be(h),
    0x08, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
  ]
}

// GIF 头 + 逻辑屏幕描述符：w(2 LE) | h(2 LE) | 3 个标志/背景字节
function gif(header, w, h) {
  return [...ascii(header), ...u16le(w), ...u16le(h), 0x00, 0x00, 0x00]
}

// BMP：文件头(14) + DIB 头宽高(12)，w/h 带符号 32 位小端
function bmp(w, h) {
  const wi = w < 0 ? w + 0x100000000 : w
  const hi = h < 0 ? h + 0x100000000 : h
  return [
    0x42, 0x4D, ...u32le(26), 0x00, 0x00, 0x00, 0x00, ...u32le(54),
    ...u32le(40), ...u32le(wi), ...u32le(hi),
  ]
}

// WebP VP8（有损）：RIFF | WEBP | "VP8 " 块：帧标签(3) | 同步码(3) | w(2) | h(2)
// wRaw/hRaw 直接落入偏移 26/28 的 16 位，TS 以 & 0x3FFF 取 14 位 → 可验证掩码。
function webpVp8(wRaw, hRaw) {
  return [
    ...ascii('RIFF'), ...u32le(30), ...ascii('WEBP'),
    ...ascii('VP8 '), ...u32le(10),
    0x9D, 0x01, 0x2A, 0x9D, 0x01, 0x2A,
    ...u16le(wRaw), ...u16le(hRaw),
  ]
}

// WebP VP8L（无损）："VP8L" 块：签名(1)=0x2F | bits(4 LE)
// bits 低 14 位 = w-1，14-27 位 = h-1，28-31 位 = alpha/版本（置位验证掩码）。
function webpVp8l(bits) {
  return [
    ...ascii('RIFF'), ...u32le(30), ...ascii('WEBP'),
    ...ascii('VP8L'), ...u32le(5),
    0x2F, ...u32le(bits),
    0x00, 0x00, 0x00, 0x00, 0x00,
  ]
}

// WebP VP8X：注意 TS 的 readWebp 对 VP8X 的宽读自偏移 18 的 3 字节小端，高读自
// 偏移 21。偏移 18-20 在标准布局中是 chunk size 低 2 字节 + flags 字节，偏移
// 21-23 是标准布局的 width-1 —— TS 与标准布局有偏差。本构建函数按 TS 实际读取
// 的偏移构造字节：tsWMinus1 编码进偏移 18-20（chunk size 低 2 字节 + flags），
// tsHMinus1 编码进偏移 21-23；TS 读不到的字段（偏移 24-26 的 height-1 等）填 0。
function webpVp8x(tsWMinus1, tsHMinus1) {
  return [
    ...ascii('RIFF'), ...u32le(30), ...ascii('WEBP'),
    ...ascii('VP8X'),
    0x0A, 0x00, ...u16le(tsWMinus1 & 0xFFFF), (tsWMinus1 >>> 16) & 0xFF,
    ...u24le(tsHMinus1 & 0xFFFFFF),
    ...u24le(0), ...u24le(0),
  ]
}

// TIFF 小端（II），条目 type 3（SHORT）
function tiffII(width, height) {
  const entry = (tag, value) => [
    ...u16le(tag), 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
    ...u16le(value), 0x00, 0x00,
  ]
  return [
    0x49, 0x49, 0x2A, 0x00, ...u32le(8),
    ...u16le(2),
    ...entry(0x0100, width), ...entry(0x0101, height),
    0x00, 0x00, 0x00, 0x00,
  ]
}

// TIFF 大端（MM），条目 type 3（SHORT）
function tiffMM(width, height) {
  const entry = (tag, value) => [
    ...u16be(tag), 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,
    ...u16be(value), 0x00, 0x00,
  ]
  return [
    0x4D, 0x4D, 0x00, 0x2A, ...u32be(8),
    ...u16be(2),
    ...entry(0x0100, width), ...entry(0x0101, height),
    0x00, 0x00, 0x00, 0x00,
  ]
}

// TIFF 小端，条目 type 4（LONG）→ r32 路径
function tiffLong(width, height) {
  const entry = (tag, value) => [
    ...u16le(tag), 0x04, 0x00, 0x01, 0x00, 0x00, 0x00,
    ...u32le(value),
  ]
  return [
    0x49, 0x49, 0x2A, 0x00, ...u32le(8),
    ...u16le(2),
    ...entry(0x0100, width), ...entry(0x0101, height),
    0x00, 0x00, 0x00, 0x00,
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// 用例：expected 手工按规范算好（[w, h] 或 null，null = 应无法读取尺寸）
// ─────────────────────────────────────────────────────────────────────────────

const CASES = [
  // JPEG：SOF0/SOF1/SOF2 各 1（h=120/w=240、h=64/w=96、h=48/w=72）
  { name: 'jpeg-sof0', ext: '.jpg', bytes: jpegSof(0xC0, 120, 240), expected: [240, 120] },
  { name: 'jpeg-sof1', ext: '.jpeg', bytes: jpegSof(0xC1, 64, 96), expected: [96, 64] },
  { name: 'jpeg-sof2', ext: '.jpg', bytes: jpegSof(0xC2, 48, 72), expected: [72, 48] },

  // PNG / GIF87a / GIF89a / BMP（含负高度取绝对值）
  { name: 'png-ihdr', ext: '.png', bytes: pngIhdr(512, 480), expected: [512, 480] },
  { name: 'gif87a', ext: '.gif', bytes: gif('GIF87a', 128, 96), expected: [128, 96] },
  { name: 'gif89a', ext: '.gif', bytes: gif('GIF89a', 320, 240), expected: [320, 240] },
  { name: 'bmp', ext: '.bmp', bytes: bmp(24, 32), expected: [24, 32] },
  { name: 'bmp-negative-height', ext: '.bmp', bytes: bmp(40, -48), expected: [40, 48] },

  // WebP：VP8（wRaw 置高位验证 & 0x3FFF 掩码）/ VP8L（bits 置位 31 验证
  // 有符号/无符号移位等价）/ VP8X（按 TS 偏移 18/21 语义）
  { name: 'webp-vp8', ext: '.webp', bytes: webpVp8(0x8280, 0x01E0), expected: [640, 480] },
  { name: 'webp-vp8l', ext: '.webp', bytes: webpVp8l(0x80058024), expected: [37, 23] },
  { name: 'webp-vp8x', ext: '.webp', bytes: webpVp8x(120, 65), expected: [121, 66] },

  // TIFF：II/MM 各 1（SHORT 型）+ LONG 型扩展（type 4 → r32 路径）
  { name: 'tiff-ii', ext: '.tif', bytes: tiffII(30, 20), expected: [30, 20] },
  { name: 'tiff-mm', ext: '.tiff', bytes: tiffMM(18, 44), expected: [18, 44] },
  { name: 'tiff-long-type', ext: '.tif', bytes: tiffLong(300, 301), expected: [300, 301] },

  // 损坏 / 边界样本
  { name: 'too-short-11', ext: '.jpg', bytes: [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x78, 0x00, 0xF0], expected: null },
  { name: 'unknown-magic', ext: '.jpg', bytes: new Array(12).fill(0), expected: null },
  { name: 'jpeg-sof-overlong', ext: '.jpg', bytes: [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x78, 0x00, 0xF0, 0x01, 0x22, 0x00, 0x00], expected: null },
  { name: 'jpeg-sof3-unsupported', ext: '.jpg', bytes: [0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x08, 0x00, 0x78, 0x00, 0xF0, 0x01, 0x22, 0x00, 0x00], expected: null },
  { name: 'jpeg-zero-width-then-valid', ext: '.jpg', bytes: [...jpegSof(0xC0, 1, 0), ...jpegSof(0xC1, 2, 3)], expected: [3, 2] },
  { name: 'png-bad-ihdr', ext: '.png', bytes: [...ascii('\x89PNG\r\n\x1a\n'), ...u32be(13), ...ascii('ABCD'), ...new Array(16).fill(0)], expected: null },
  { name: 'png-zero-width', ext: '.png', bytes: pngIhdr(0, 5), expected: null },
  { name: 'bmp-zero-width', ext: '.bmp', bytes: bmp(0, 32), expected: null },
  { name: 'tiff-offset-out-of-range', ext: '.tif', bytes: [0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00, ...new Array(8).fill(0)], expected: null },
  { name: 'webp-truncated', ext: '.webp', bytes: [...ascii('RIFF'), ...u32le(20), ...ascii('WEBP'), ...ascii('VP8 '), ...u32le(4)], expected: null },
  { name: 'ext-tiff-fallback', ext: '.tiff', bytes: [...ascii('AA'), 0x00, 0x00, ...u32be(8), ...u16be(2), ...u16be(0x0100), 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, ...u16be(30), 0x00, 0x00, ...u16be(0x0101), 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, ...u16be(20), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], expected: [30, 20] },
  { name: 'ext-tif-null', ext: '.tif', bytes: new Array(12).fill(0), expected: null },
]

// ─────────────────────────────────────────────────────────────────────────────
// 校验：参照实现复算 ↔ 手工 expected 逐一对齐
// ─────────────────────────────────────────────────────────────────────────────

function validate() {
  const out = []
  const names = new Set()
  for (const c of CASES) {
    if (names.has(c.name)) throw new Error(`fatal: 重复 name ${c.name}`)
    names.add(c.name)
    if (!Array.isArray(c.bytes) || c.bytes.length === 0) {
      throw new Error(`fatal: case ${c.name} 字节为空`)
    }
    for (const b of c.bytes) {
      if (!Number.isInteger(b) || b < 0 || b > 255) {
        throw new Error(`fatal: case ${c.name} 含非法字节 ${b}`)
      }
    }
    if (c.expected !== null) {
      if (!Array.isArray(c.expected) || c.expected.length !== 2
          || !Number.isInteger(c.expected[0]) || !Number.isInteger(c.expected[1])
          || c.expected[0] <= 0 || c.expected[1] <= 0) {
        throw new Error(`fatal: case ${c.name} expected 非法 ${JSON.stringify(c.expected)}`)
      }
    }

    const buf = Buffer.from(c.bytes)
    const got = readDimensions(buf, c.ext)
    const gotJSON = got === null ? null : [got.width, got.height]
    if (JSON.stringify(gotJSON) !== JSON.stringify(c.expected)) {
      throw new Error(
        `fatal: case ${c.name} 参照实现 != 手工期望：got ${JSON.stringify(gotJSON)}, expected ${JSON.stringify(c.expected)}`,
      )
    }

    const dataBase64 = buf.toString('base64')
    const roundTrip = Buffer.from(dataBase64, 'base64')
    if (!buf.equals(roundTrip)) {
      throw new Error(`fatal: case ${c.name} base64 往返不一致`)
    }

    out.push({ name: c.name, ext: c.ext, dataBase64, expected: c.expected })
  }
  return out
}

// ─────────────────────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────────────────────

function main() {
  const check = process.argv.includes('--check')

  const cases = validate()
  const json = JSON.stringify({
    source: 'desktop/src/main/services/image/decoders/fast-dimensions.ts',
    cases,
  }, null, 2) + '\n'

  if (check) {
    if (!fs.existsSync(FIXTURE_PATH)) {
      console.error(`--check 失败：fixture 不存在 ${FIXTURE_PATH}（先运行生成模式）`)
      process.exit(1)
    }
    const existing = fs.readFileSync(FIXTURE_PATH, 'utf8')
    if (existing !== json) {
      console.error(
        `--check 失败：fixture 漂移（${cases.length} cases）\n` +
          `现有文件：${FIXTURE_PATH}\n请重新生成并提交。`,
      )
      process.exit(1)
    }
    console.log(`OK: ${cases.length} cases 与 ${FIXTURE_PATH} 完全一致`)
    return
  }

  fs.mkdirSync(path.dirname(FIXTURE_PATH), { recursive: true })
  fs.writeFileSync(FIXTURE_PATH, json)
  console.log(`已写入 ${FIXTURE_PATH}（${cases.length} cases）`)
}

main()
