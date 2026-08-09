// src/main/services/helper/helper-client.ts
// gather-core-helper 客户端（1.3）：以 child_process 启动 Swift helper，走
// stdout JSON 行协议。线协议见 desktop/native/gather-core/Sources/GatherCore/IPC/
// HelperMessage.swift：每行一个请求 { id, command, payload? }，每行一个响应
// { id, ok, payload?, error? }。
//
// payload 在线上是 base64 编码的 Data（Swift Foundation JSONEncoder 对 Data 的
// 标准编码）；helper 侧同时容忍普通 JSON 字符串 payload（冒烟便捷形态，按 UTF-8
// 字节承载），但本客户端一律按标准 base64 形态收发，并把 base64 还原为 UTF-8
// 字符串暴露给调用方（本项目 payload 均为 JSON 文本，二进制负载尚无场景）。
// helper 的日志走 stderr，stdout 只承载 JSON 行，互不污染。

import { spawn } from 'child_process'
import type { ChildProcessWithoutNullStreams } from 'child_process'
import * as path from 'path'
import { app } from 'electron'

export interface HelperRequest {
  id: string
  command: string
  payload?: string
}

export interface HelperResponse {
  id: string
  ok: boolean
  payload?: string
  error?: string
}

// 单请求超时：helper 卡死时不能让调用方永久挂起。
const REQUEST_TIMEOUT_MS = 10_000

let nextRequestId = 1
let helperProcess: ChildProcessWithoutNullStreams | null = null
let stdoutBuffer = ''

const pending = new Map<string, {
  resolve: (response: HelperResponse) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
}>()

// 默认路径为打包后的资源目录约定 desktop/native/gather-core-helper（macOS 可
// 执行文件无扩展名）；本地开发时产物位于 gather-core/.build/<config>/ 下，
// 通过环境变量 GATHER_CORE_HELPER_PATH 指向真实可执行文件。
function resolveHelperPath(): string {
  return process.env.GATHER_CORE_HELPER_PATH ?? path.join(app.getAppPath(), 'native', 'gather-core-helper')
}

function rejectAllPending(message: string): void {
  for (const [id, request] of pending) {
    clearTimeout(request.timer)
    request.reject(new Error(message))
    pending.delete(id)
  }
}

function handleLine(line: string): void {
  const trimmed = line.trim()
  if (!trimmed) return
  let response: HelperResponse
  try {
    response = JSON.parse(trimmed) as HelperResponse
  } catch {
    console.warn('[helper] 忽略无法解析的 stdout 行:', trimmed)
    return
  }
  const request = pending.get(response.id)
  if (!request) {
    // 已超时或被拒后的迟到响应：无人认领，丢弃。
    console.warn(`[helper] 收到无主响应 id=${response.id}，忽略`)
    return
  }
  clearTimeout(request.timer)
  pending.delete(response.id)
  request.resolve({
    ...response,
    payload: response.payload === undefined ? undefined : Buffer.from(response.payload, 'base64').toString('utf8'),
  })
}

function ensureStarted(): ChildProcessWithoutNullStreams {
  if (helperProcess !== null && helperProcess.exitCode === null) {
    return helperProcess
  }
  const child = spawn(resolveHelperPath(), [], { stdio: ['pipe', 'pipe', 'pipe'] })
  helperProcess = child
  stdoutBuffer = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk: string) => {
    stdoutBuffer += chunk
    const lines = stdoutBuffer.split('\n')
    stdoutBuffer = lines.pop() ?? ''
    for (const line of lines) handleLine(line)
  })
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk: string) => {
    const text = chunk.trimEnd()
    if (text) console.warn('[helper]', text)
  })
  child.on('error', (error) => {
    helperProcess = null
    rejectAllPending(`gather-core-helper 启动失败: ${error.message}`)
  })
  child.on('exit', (code, signal) => {
    helperProcess = null
    rejectAllPending(`gather-core-helper 进程退出 code=${code} signal=${signal}`)
  })
  return child
}

/** 通用调用：命令 + 可选 payload（UTF-8 文本），按 id 匹配响应。 */
export function invoke(command: string, payload?: string): Promise<HelperResponse> {
  const id = String(nextRequestId++)
  const request: HelperRequest = { id, command }
  if (payload !== undefined) {
    request.payload = Buffer.from(payload, 'utf8').toString('base64')
  }
  return new Promise<HelperResponse>((resolve, reject) => {
    let child: ChildProcessWithoutNullStreams
    try {
      child = ensureStarted()
    } catch (error) {
      reject(error instanceof Error ? error : new Error(String(error)))
      return
    }
    const timer = setTimeout(() => {
      if (pending.delete(id)) {
        reject(new Error(`gather-core-helper 请求超时（command=${command} id=${id}）`))
      }
    }, REQUEST_TIMEOUT_MS)
    pending.set(id, { resolve, reject, timer })
    child.stdin.write(`${JSON.stringify(request)}\n`, (error) => {
      if (error && pending.delete(id)) {
        clearTimeout(timer)
        reject(new Error(`gather-core-helper 写入失败: ${error.message}`))
      }
    })
  })
}

/** 冒烟/自检：echo 回显（1.3 验收：Electron 壳调 core 解码返回结果）。 */
export function invokeEcho(payload?: string): Promise<HelperResponse> {
  return invoke('echo', payload)
}
