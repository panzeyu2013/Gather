/**
 * @jest-environment node
 */

jest.mock('electron', () => ({
  BrowserWindow: {
    getAllWindows: jest.fn(() => []),
  },
  app: {
    isPackaged: false,
    quit: jest.fn(),
  },
}))

import { encode, decode } from '@msgpack/msgpack'
import { deepSanitize, TOP_LEVEL_BLOCKED, NESTED_BLOCKED } from './python-bridge'

const ALL_BLOCKED = new Set([...TOP_LEVEL_BLOCKED, ...NESTED_BLOCKED])

const MAX_MESSAGE_SIZE = 100 * 1024 * 1024

function buildFrame(message: unknown): Buffer {
  const payload = Buffer.from(encode(message))
  const header = Buffer.alloc(4)
  header.writeUint32BE(payload.byteLength, 0)
  return Buffer.concat([header, payload])
}

function parseFrame(buffer: Buffer): { messages: unknown[]; remaining: Buffer } {
  const messages: unknown[] = []
  let buf = buffer

  while (buf.length >= 4) {
    const length = buf.readUint32BE(0)

    if (length > MAX_MESSAGE_SIZE) {
      const skipLen = Math.min(4 + length, buf.length)
      buf = buf.subarray(skipLen)
      continue
    }

    if (buf.length < 4 + length) break

    const payload = buf.subarray(4, 4 + length)
    buf = buf.subarray(4 + length)

    try {
      messages.push(decode(payload))
    } catch {
      continue
    }
  }

  return { messages, remaining: buf }
}

describe('Message framing (4-byte length prefix + msgpack)', () => {
  it('builds a frame with correct 4-byte big-endian header', () => {
    const msg = { id: 1, type: 'test', payload: 'hello' }
    const frame = buildFrame(msg)

    const headerLength = frame.readUint32BE(0)
    const body = frame.subarray(4)

    expect(frame.byteLength).toBe(4 + headerLength)
    expect(headerLength).toBeGreaterThan(0)
    expect(body.byteLength).toBe(headerLength)
  })

  it('round-trips a message through build / parse', () => {
    const original = { id: 42, type: 'session.list', data: { name: 'foo', items: [1, 2, 3] } }
    const frame = buildFrame(original)
    const { messages, remaining } = parseFrame(frame)

    expect(remaining.byteLength).toBe(0)
    expect(messages).toHaveLength(1)
    expect(messages[0]).toEqual(original)
  })

  it('parses multiple concatenated frames', () => {
    const msgs = [
      { id: 1, type: 'a' },
      { id: 2, type: 'b' },
      { id: 3, type: 'c' },
    ]
    const concatenated = Buffer.concat(msgs.map(buildFrame))
    const { messages, remaining } = parseFrame(concatenated)

    expect(remaining.byteLength).toBe(0)
    expect(messages).toEqual(msgs)
  })

  it('leaves partial frame in remaining buffer', () => {
    const frame = buildFrame({ id: 1, type: 'complete' })
    const partial = frame.subarray(0, frame.byteLength - 1)
    const { messages, remaining } = parseFrame(partial)

    expect(messages).toHaveLength(0)
    expect(remaining.byteLength).toBe(partial.byteLength)
  })
})

describe('MAX_MESSAGE_SIZE check', () => {
  it('rejects a frame whose declared length exceeds MAX_MESSAGE_SIZE', () => {
    const badHeader = Buffer.alloc(4)
    badHeader.writeUint32BE(MAX_MESSAGE_SIZE + 1, 0)

    const garbage = Buffer.alloc(8)
    garbage.writeUint32BE(42, 4)

    const buf = Buffer.concat([badHeader, garbage])
    const { messages, remaining } = parseFrame(buf)

    expect(messages).toHaveLength(0)
    // The oversized frame should have been skipped
    expect(remaining.byteLength).toBe(0)
  })

  it('skips oversized frame and continues to read next valid frame', () => {
    // Use a small local limit so we can construct a complete oversized frame
    const localMax = 1024
    const badBody = Buffer.alloc(localMax + 1, 0xff)
    const badHeader = Buffer.alloc(4)
    badHeader.writeUint32BE(localMax + 1, 0)
    const badFrame = Buffer.concat([badHeader, badBody])

    const goodFrame = buildFrame({ id: 1, type: 'good' })
    const buf = Buffer.concat([badFrame, goodFrame])

    // Parse with a custom max matching the test data
    function parseWithMax(buffer: Buffer): unknown[] {
      const messages: unknown[] = []
      let cur = buffer
      while (cur.length >= 4) {
        const length = cur.readUint32BE(0)
        if (length > localMax) {
          const skipLen = Math.min(4 + length, cur.length)
          cur = cur.subarray(skipLen)
          continue
        }
        if (cur.length < 4 + length) break
        const payload = cur.subarray(4, 4 + length)
        cur = cur.subarray(4 + length)
        try { messages.push(decode(payload)) } catch { continue }
      }
      return messages
    }

    const messages = parseWithMax(buf)
    expect(messages).toHaveLength(1)
    expect(messages[0]).toEqual({ id: 1, type: 'good' })
  })

  it('allows a message at the size limit', () => {
    const localMax = 2048
    const largeString = 'x'.repeat(localMax - 50)
    const msg = { id: 1, type: 'large', data: largeString }
    const frame = buildFrame(msg)

    const declared = frame.readUint32BE(0)
    expect(declared).toBeLessThanOrEqual(localMax)

    // Parse with matching limit
    function parseWithMax(buffer: Buffer): unknown[] {
      const messages: unknown[] = []
      let cur = buffer
      while (cur.length >= 4) {
        const length = cur.readUint32BE(0)
        if (length > localMax) {
          const skipLen = Math.min(4 + length, cur.length)
          cur = cur.subarray(skipLen)
          continue
        }
        if (cur.length < 4 + length) break
        const payload = cur.subarray(4, 4 + length)
        cur = cur.subarray(4 + length)
        try { messages.push(decode(payload)) } catch { continue }
      }
      return messages
    }

    const messages = parseWithMax(frame)
    expect(messages).toHaveLength(1)
  })
})

describe('Error handling for invalid responses', () => {
  it('skips frame with undecodable msgpack payload', () => {
    const header = Buffer.alloc(4)
    header.writeUint32BE(10, 0)
    const undecodable = Buffer.concat([header, Buffer.alloc(10, 0xfe)])
    const goodFrame = buildFrame({ id: 1, type: 'valid' })
    const buf = Buffer.concat([undecodable, goodFrame])

    const { messages } = parseFrame(buf)
    expect(messages).toHaveLength(1)
    expect(messages[0]).toEqual({ id: 1, type: 'valid' })
  })

  it('distinguishes ok and error responses by msg.ok flag', () => {
    const okMsg = { id: 1, ok: true, data: { result: 42 } }
    const errMsg = { id: 2, ok: false, error: { type: 'ValueError', message: 'bad input' } }

    const frames = Buffer.concat([buildFrame(okMsg), buildFrame(errMsg)])
    const { messages } = parseFrame(frames)

    expect(messages).toHaveLength(2)

    const ok = messages[0] as Record<string, unknown>
    expect(ok.ok).toBe(true)
    expect(ok.data).toEqual({ result: 42 })

    const err = messages[1] as Record<string, unknown>
    expect(err.ok).toBe(false)
    expect(err.error).toEqual({ type: 'ValueError', message: 'bad input' })
  })

  it('decodes null / empty payloads gracefully', () => {
    const msg = { id: 1, ok: true, data: null }
    const frame = buildFrame(msg)
    const { messages } = parseFrame(frame)

    expect(messages).toHaveLength(1)
    expect((messages[0] as Record<string, unknown>).data).toBeNull()
  })
})

describe('deepSanitize', () => {
  it('blocks __proto__ at the top level', () => {
    const input = JSON.parse('{"__proto__":{"polluted":true},"safe":"value"}')
    const result = deepSanitize(input, NESTED_BLOCKED) as Record<string, unknown>
    expect(result).toEqual({ safe: 'value' })
  })

  it('blocks __proto__ at any nesting depth', () => {
    const input = JSON.parse('{"level1":{"level2":{"__proto__":{"polluted":true},"nestedSafe":"ok"}}}')
    const result = deepSanitize(input, NESTED_BLOCKED) as Record<string, unknown>
    const l1 = result.level1 as Record<string, unknown>
    const l2 = l1.level2 as Record<string, unknown>
    expect(l2).toEqual({ nestedSafe: 'ok' })
  })

  it('blocks constructor key', () => {
    const input = { constructor: 'evil', valid: 42 }
    const result = deepSanitize(input, NESTED_BLOCKED) as Record<string, unknown>
    expect(Object.hasOwn(result, 'constructor')).toBe(false)
    expect(result.valid).toBe(42)
  })

  it('blocks prototype key', () => {
    const input = { prototype: 'evil', valid: 42 }
    const result = deepSanitize(input, NESTED_BLOCKED) as Record<string, unknown>
    expect(Object.hasOwn(result, 'prototype')).toBe(false)
    expect(result.valid).toBe(42)
  })

  it('blocks id, type, ok, event keys (from TOP_LEVEL_BLOCKED)', () => {
    const input = { id: 1, type: 'cmd', ok: true, event: 'push', realData: 'hello' }
    const result = deepSanitize(input, TOP_LEVEL_BLOCKED) as Record<string, unknown>
    expect(Object.hasOwn(result, 'id')).toBe(false)
    expect(Object.hasOwn(result, 'type')).toBe(false)
    expect(Object.hasOwn(result, 'ok')).toBe(false)
    expect(Object.hasOwn(result, 'event')).toBe(false)
    expect(result.realData).toBe('hello')
  })

  it('sanitizes arrays of objects', () => {
    const input = {
      items: [
        JSON.parse('{"__proto__":"bad","name":"a"}'),
        JSON.parse('{"constructor":"bad","name":"b"}'),
      ],
    }
    const result = deepSanitize(input, ALL_BLOCKED) as Record<string, unknown>
    const items = result.items as Record<string, unknown>[]
    expect(items[0]).toEqual({ name: 'a' })
    expect(items[1]).toEqual({ name: 'b' })
  })

  it('returns primitives unchanged', () => {
    expect(deepSanitize(42, NESTED_BLOCKED)).toBe(42)
    expect(deepSanitize('hello', NESTED_BLOCKED)).toBe('hello')
    expect(deepSanitize(null, NESTED_BLOCKED)).toBeNull()
    expect(deepSanitize(true, NESTED_BLOCKED)).toBe(true)
  })

  it('returns Uint8Array unchanged (not treated as plain object)', () => {
    const buf = new Uint8Array([1, 2, 3])
    const result = deepSanitize(buf, NESTED_BLOCKED)
    expect(result).toBe(buf)
  })
})

describe('parseFrame edge cases', () => {
  it('returns empty messages when buffer is less than 4 bytes', () => {
    const buf = Buffer.from([0x00, 0x01])
    const { messages, remaining } = parseFrame(buf)
    expect(messages).toHaveLength(0)
    expect(remaining.byteLength).toBe(2)
  })

  it('handles payload shorter than declared length', () => {
    const header = Buffer.alloc(4)
    header.writeUint32BE(100, 0)
    const shortBody = Buffer.from([0x01, 0x02])
    const buf = Buffer.concat([header, shortBody])
    const { messages, remaining } = parseFrame(buf)
    expect(messages).toHaveLength(0)
    expect(remaining.byteLength).toBe(6)
  })

  it('handles an empty buffer gracefully', () => {
    const { messages, remaining } = parseFrame(Buffer.alloc(0))
    expect(messages).toHaveLength(0)
    expect(remaining.byteLength).toBe(0)
  })
})

describe('encode → decode roundtrip', () => {
  it('round-trips an object without data loss', () => {
    const original = { hello: 'world', count: 42, flag: true, list: [1, 2, 3] }
    const encoded = encode(original)
    const decoded = decode(encoded)
    expect(decoded).toEqual(original)
  })

  it('round-trips nested structures', () => {
    const original = { nested: { deep: { value: 'test' } }, arr: [{ a: 1 }, { b: 2 }] }
    const encoded = encode(original)
    const decoded = decode(encoded)
    expect(decoded).toEqual(original)
  })

  it('round-trips using buildFrame / parseFrame', () => {
    const original = { id: 42, type: 'session.list', data: { name: 'foo', items: [1, 2, 3] } }
    const frame = buildFrame(original)
    const frameRoundtrip = parseFrame(frame)
    expect(frameRoundtrip.messages).toHaveLength(1)
    expect(frameRoundtrip.messages[0]).toEqual(original)
  })
})
