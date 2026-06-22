// src/main/python-bridge.ts
// Python 子进程管理 + MessagePack 协议通信

import { BrowserWindow, app, dialog } from 'electron'
import { encode, decode } from '@msgpack/msgpack'
import { join, delimiter, resolve } from 'path'
import { homedir, tmpdir } from 'os'
import { existsSync } from 'fs'
import type { ChildProcess } from 'child_process'
import { spawn } from 'child_process'
import { isRecord } from '@gather/shared'

const MAX_MESSAGE_SIZE = 100 * 1024 * 1024 // 100MB 上限，防止 OOM
const MAX_BUFFER_SIZE = 200 * 1024 * 1024 // 200MB 缓冲区上限

function resolvePythonPath(name: string): string {
  const paths = (process.env.PATH || '').split(delimiter)
  for (const dir of paths) {
    const candidate = join(dir, name)
    if (existsSync(candidate)) return candidate
  }
  throw new Error(`Python interpreter "${name}" not found on PATH`)
}

function resolveBundledPythonPath(): string | null {
  const bundleDir = join(process.resourcesPath, 'engine', '.venv', 'bin')
  const candidates = ['python3', 'python']
  for (const name of candidates) {
    const candidate = join(bundleDir, name)
    if (existsSync(candidate)) return candidate
  }
  return null
}

function resolveDevelopmentPythonPath(): string | null {
  const repoRoot = resolve(__dirname, '../../..')
  const candidates = process.platform === 'win32'
    ? [
        join(repoRoot, '.venv', 'Scripts', 'python.exe'),
        join(repoRoot, '.venv', 'Scripts', 'python'),
      ]
    : [
        join(repoRoot, '.venv', 'bin', 'python3'),
        join(repoRoot, '.venv', 'bin', 'python'),
      ]

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  return null
}

interface Pending {
  resolve: (value: unknown) => void
  reject: (error: Error) => void
}

interface PythonError extends Error {
  pythonTraceback?: unknown
  pythonErrorType?: unknown
}

export function deepSanitize(obj: unknown, blocked: Set<string>): unknown {
  if (Array.isArray(obj)) return obj.map(v => deepSanitize(v, blocked))
  if (isRecord(obj) && !(obj instanceof Uint8Array)) {
    const clean: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(obj)) {
      if (blocked.has(k)) continue
      clean[k] = deepSanitize(v, blocked)
    }
    return clean
  }
  return obj
}
export const TOP_LEVEL_BLOCKED = new Set(['id', 'type', 'ok', 'event'])
export const NESTED_BLOCKED = new Set(['__proto__', 'constructor', 'prototype'])

const ALLOWED_PYTHON_EVENTS = new Set(['progress', 'python:ready', 'python:disconnected'])

export class PythonBridge {
  private proc: ChildProcess | null = null
  private pending = new Map<number, Pending>()
  private _messageId = 0
  private _buffer = Buffer.alloc(0)
  private eventListeners = new Map<string, Set<(data: unknown) => void>>()
  // NOTE: The ! definite assignment assertions on readyResolve/readyReject are fragile.
  // They are assigned synchronously inside the readyPromise constructor, and reassigned
  // on every _launch() call. If the promise constructor were refactored to be async or
  // deferred, these could be undefined when accessed. Consider using a single Deferred
  // utility class instead.
  private readyResolve!: () => void
  private readyReject!: (err: Error) => void
  private readyPromise = new Promise<void>((resolve, reject) => {
    this.readyResolve = resolve
    this.readyReject = reject
  })
  private _pythonPath: string = ''
  private _restartCount = 0
  private _maxRestarts = 3
  private _requestTimeout = 120_000
  private _intentionalShutdown = false
  private _spawnFailed = false
  private _launching = false
  private _restartTimer: ReturnType<typeof setTimeout> | null = null
  private _generation = 0
  private _readySettled = false

  get isRunning(): boolean {
    return this.proc !== null && !this.proc.killed
  }

  /** Immediately SIGKILL the Python process (failsafe for will-quit). */
  forceKill(): void {
    if (this.proc && !this.proc.killed) {
      this.proc.kill('SIGKILL')
    }
  }

  /** 启动 Python 引擎，等待就绪信号 */
  async start(pythonPath: string): Promise<void> {
    this._pythonPath = pythonPath
    this._restartCount = 0
    await this._launch()
  }

  private async _launch(): Promise<void> {
    if (this._launching) return
    this._launching = true
    const gen = ++this._generation
    try {
    this._spawnFailed = false
    this._messageId = 0
    const enginePath = app.isPackaged
      ? join(process.resourcesPath, 'engine', 'engine.py')
      : join(__dirname, '../../engine/engine.py')

    this.readyPromise = new Promise<void>((resolve, reject) => {
      this.readyResolve = resolve
      this.readyReject = reject
    })
    this._readySettled = false

    const resolvedPath = !app.isPackaged
      ? (resolveDevelopmentPythonPath() || resolvePythonPath(this._pythonPath))
      : (resolveBundledPythonPath() || resolvePythonPath(this._pythonPath))
    this.proc = spawn(resolvedPath, ['-I', enginePath], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        PATH: process.platform === 'darwin'
          ? `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH || '/usr/bin:/bin'}`
          : process.env.PATH || '/usr/bin:/bin',
        PYTHONUNBUFFERED: '1',
        HOME: homedir(),
        TMPDIR: tmpdir(),
        GATHER_DEBUG: app.isPackaged ? '0' : '1',
      },
    })

    const proc = this.proc
    if (!proc || !proc.stdout || !proc.stderr) {
      this._spawnFailed = true
      this.readyReject(new Error('Failed to create child process streams'))
      throw new Error('Child process streams not available')
    }
    proc.stdout.on('data', (chunk: Buffer) => this.handleStdout(chunk))
    proc.stderr.on('data', (d: Buffer) => process.stderr.write(`[python] ${d}`))

    proc.on('error', (err) => {
      console.error('[gather] Python engine failed to start:', err.message)
      this.readyReject(new Error('Python process exited'))
      this._spawnFailed = true
      app.exit(1)
    })

    proc.on('exit', (code) => {
      if (this._generation !== gen) return
      if (this._spawnFailed) return
      console.log(`[gather] Python engine exited (code ${code})`)
      if (this.proc === proc) this.proc = null
      if (!this._readySettled) {
        this.readyReject(new Error(`Python engine exited (code ${code}) before ready`))
      }
      this.pending.forEach((p) => p.reject(new Error('Python engine exited')))
      this.pending.clear()
      BrowserWindow.getAllWindows().forEach((win) => {
        win.webContents.send('python:event', 'python:disconnected', { code })
      })
      if (this._intentionalShutdown) {
        return
      }
      if (this._restartCount < this._maxRestarts) {
        const delay = Math.min(1000 * Math.pow(2, this._restartCount), 8000)
        this._restartCount++
        console.log(`[gather] Restarting Python engine in ${delay}ms (attempt ${this._restartCount}/${this._maxRestarts})`)
        this._restartTimer = setTimeout(() => { this._launch().catch((err) => { console.error(`Engine restart attempt failed:`, err) }) }, delay)
      } else {
        this.eventListeners.clear()
        if (code !== 0) {
          dialog.showErrorBox('Engine Failure', 'The Python engine could not be started. The application will now quit.')
          app.exit(1)
        }
      }
    })

    // 等待就绪信号
    await this.readyPromise
    console.log('[gather] Python engine ready')
    if (this._restartCount > 0) {
      BrowserWindow.getAllWindows().forEach((win) => {
        win.webContents.send('python:ready')
        win.webContents.send('python:event', 'python:ready')
      })
    }
    } finally {
      this._launching = false
    }
  }

  /** 发送命令到 Python，返回 Promise<结果> */
  async send(cmd: string, params: Record<string, unknown> = {}): Promise<unknown> {
    if (!this.proc) throw new Error('Python engine not running')

    let id: number
    if (this._messageId >= Number.MAX_SAFE_INTEGER) {
      this._messageId = 1
    } else {
      this._messageId++
    }
    let _idIterGuard = 0
    while (this.pending.has(this._messageId)) {
      if (this._messageId >= Number.MAX_SAFE_INTEGER) this._messageId = 1
      else this._messageId++
      if (++_idIterGuard > 1000) throw new Error('Message ID allocation overflow: too many collisions')
    }
    id = this._messageId
    const clean: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(params)) {
      if (!TOP_LEVEL_BLOCKED.has(k)) {
        clean[k] = v
      }
    }
    const sanitized = deepSanitize(clean, NESTED_BLOCKED) as Record<string, unknown>
    const message = encode({ id, type: cmd, ...sanitized })

    if (message.byteLength > MAX_MESSAGE_SIZE) {
      throw new Error(`Message too large: ${message.byteLength} bytes`)
    }

    let timer: ReturnType<typeof setTimeout>
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`Request ${cmd} timed out after ${this._requestTimeout}ms`))
      }, this._requestTimeout)
    })
    timeout.catch(() => {}) // suppress unhandled rejection when main promise wins the race

    const promise = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })

      const header = Buffer.alloc(4)
      header.writeUint32BE(message.byteLength, 0)
      const body = Buffer.from(message.buffer, message.byteOffset, message.byteLength)
      try {
        this.proc!.stdin!.write(Buffer.concat([header, body]))
      } catch (err) {
        this.pending.delete(id)
        reject(err instanceof Error ? err : new Error(String(err)))
      }
    })

    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer!))
  }

  /** 监听 Python 推送事件 */
  onEvent(event: string, callback: (data: unknown) => void): () => void {
    if (!this.eventListeners.has(event)) {
      this.eventListeners.set(event, new Set())
    }
    this.eventListeners.get(event)!.add(callback)
    return () => this.eventListeners.get(event)?.delete(callback)
  }

  /** 关闭 Python 引擎 */
  kill(): void {
    if (!this.proc || this.proc.killed) return
    this._intentionalShutdown = true
    if (this._restartTimer) { clearTimeout(this._restartTimer); this._restartTimer = null }

    const SHUTDOWN_TIMEOUT = 2000
    const FORCE_KILL_TIMEOUT = 2000

    // 优雅关闭：发送 shutdown 命令
    const header = Buffer.alloc(4)
    const message = encode({ id: ++this._messageId, type: 'shutdown' })
    header.writeUint32BE(message.byteLength, 0)
    const body = Buffer.from(message.buffer, message.byteOffset, message.byteLength)
    try {
      this.proc.stdin!.write(Buffer.concat([header, body]))
    } catch (err) { console.debug('shutdown write failed (stdin may be closed):', err) }

    const procRef = this.proc
    // 2 秒后强制 SIGTERM
    const termTimer = setTimeout(() => {
      if (procRef && !procRef.killed) {
        procRef.kill('SIGTERM')
        // 再给 2 秒，不退出则 SIGKILL
        const killTimer = setTimeout(() => {
          if (procRef && !procRef.killed) {
            procRef.kill('SIGKILL')
          }
        }, FORCE_KILL_TIMEOUT)
        procRef.once('exit', () => clearTimeout(killTimer))
      }
    }, SHUTDOWN_TIMEOUT)
    this.proc.once('exit', () => clearTimeout(termTimer))
  }

  // ── 内部 ──

  private handleStdout(chunk: Buffer): void {
    try {
      this._buffer = Buffer.concat([this._buffer, chunk])

      if (this._buffer.length < 4) return

      if (this._buffer.length > MAX_BUFFER_SIZE) {
        console.error(`[gather] Buffer overflow: ${this._buffer.length} bytes, draining before reset`)
        try {
          while (this._buffer.length >= 4 && this._buffer.length >= 4 + this._buffer.readUint32BE(0)) {
            const length = this._buffer.readUint32BE(0)
            if (length > MAX_MESSAGE_SIZE) {
              this._buffer = this._buffer.subarray(4 + Math.min(length, this._buffer.length - 4))
              continue
            }
            const payload = this._buffer.subarray(4, 4 + length)
            this._buffer = this._buffer.subarray(4 + length)
            try {
              const parsed = decode(payload)
              if (isRecord(parsed)) this.dispatch(parsed)
            } catch { /* skip malformed frame during drain */ }
          }
        } catch { /* drain failed, proceed with reset */ }
        if (this._buffer.length > MAX_BUFFER_SIZE) {
          console.error(`[gather] Buffer still overflowed after drain, resetting`)
          this._buffer = Buffer.alloc(0)
          for (const p of this.pending.values()) {
            p.reject(new Error('Buffer overflow: disconnected from engine'))
          }
          this.pending.clear()
        }
        return
      }

      while (this._buffer.length >= 4) {
        const length = this._buffer.readUint32BE(0)

        if (length > MAX_MESSAGE_SIZE) {
          console.error(`[gather] Message too large: ${length} bytes, discarding frame`)
          try {
            const payloadToTry = this._buffer.subarray(4, Math.min(this._buffer.length, 4 + 1024 * 1024))
            const parsed = decode(payloadToTry)
            if (isRecord(parsed)) {
            const id = typeof parsed.id === 'number' ? parsed.id : undefined
            if (id !== undefined) {
              const pending = this.pending.get(id)
              if (pending) {
                this.pending.delete(id)
                pending.reject(new Error(`Message exceeds maximum size: ${length} bytes`))
              }
            }
            }
          } catch {
            // Attempt to extract the message ID from an oversized frame so the
            // specific request can be rejected rather than timing out silently.
            // This handles cases where a slightly oversized payload still has
            // a parseable header in the first few bytes.
            console.error(`[gather] Corrupted oversized frame, attempting ID recovery`)
            let idRecovered = false
            for (const trySize of [256, 128, 64]) {
              try {
                const tinySlice = this._buffer.subarray(4, Math.min(this._buffer.length, 4 + trySize))
                const partial = decode(tinySlice)
                if (isRecord(partial)) {
                const id = typeof partial.id === 'number' ? partial.id : undefined
                if (id !== undefined) {
                  const pending = this.pending.get(id)
                  if (pending) {
                    this.pending.delete(id)
                    pending.reject(new Error(`Message exceeds maximum size: ${length} bytes`))
                    idRecovered = true
                  }
                  break
                }
                }
              } catch {
                continue
              }
            }
            if (!idRecovered) {
              console.error(`[gather] Unable to recover any pending ID from corrupted oversized frame; discarding frame only`)
            }
          }
          const skipLen = Math.min(4 + length, this._buffer.length)
          this._buffer = this._buffer.subarray(skipLen)
          continue
        }

        if (this._buffer.length < 4 + length) break

        const payload = this._buffer.subarray(4, 4 + length)
        this._buffer = this._buffer.subarray(4 + length)

        try {
          const parsed = decode(payload)
          if (isRecord(parsed)) this.dispatch(parsed)
        } catch (err: unknown) {
          console.error('[gather] Failed to decode Python message:', err)
        }
      }
    } catch (err: unknown) {
      console.error('[gather] handleStdout buffer error:', err)
      this._buffer = Buffer.alloc(0)
    }
  }

  private dispatch(msg: Record<string, unknown>): void {
    if (typeof msg.type !== 'string') return
    // 就绪信号
    if (msg.type === 'ready') {
      if (msg.version !== '3.0.0') {
        console.warn(`[gather] Python engine version mismatch: expected 3.0.0, got ${msg.version}`)
      }
      this._readySettled = true
      this.readyResolve()
      return
    }

    // 就绪信号（事件格式）
    if (msg.type === 'event' && msg.event === 'python:ready') {
      const data = msg.data as Record<string, unknown> | undefined
      if (data && data.version !== '3.0.0') {
        console.warn(`[gather] Python engine version mismatch: expected 3.0.0, got ${data.version}`)
      }
      this._readySettled = true
      this.readyResolve()
      return
    }

    // 命令响应
    if (msg.id !== undefined) {
      const id = typeof msg.id === 'number' ? msg.id : Number(msg.id)
      if (!Number.isFinite(id)) return
      const pending = this.pending.get(id)
      if (pending) {
        this.pending.delete(id)
        if (msg.ok) {
          pending.resolve(msg.data)
        } else {
          const errInfo = msg.error
          if (isRecord(errInfo)) {
            const msgText = `${errInfo.type || 'Error'}: ${errInfo.message || 'Python error'}`
            const err: PythonError = Object.assign(new Error(msgText), {
              pythonTraceback: errInfo.traceback,
              pythonErrorType: errInfo.type,
            })
            pending.reject(err)
          } else {
            pending.reject(new Error(String(errInfo || 'Python error')))
          }
        }
      }
      return
    }

    // 事件推送
    if (msg.type === 'event') {
      const eventName = msg.event
      if (typeof eventName !== 'string' || !ALLOWED_PYTHON_EVENTS.has(eventName)) {
        console.warn(`[gather] Ignoring unknown or invalid Python event: ${eventName}`)
        return
      }
      const data = msg.data
      this.eventListeners.get(eventName)?.forEach((cb) => {
        try { cb(data) } catch (err) { console.error('[gather] Event listener error:', err) }
      })

      // 通知渲染进程的事件系统（供 preload → window.gather.onEvent 使用）
      BrowserWindow.getAllWindows().forEach((win) => {
        win.webContents.send('python:event', eventName, data)
      })
    }
  }
}
