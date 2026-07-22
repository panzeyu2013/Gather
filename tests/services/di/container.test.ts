import { describe, it, expect, beforeEach } from 'vitest'
import { container } from '../../../desktop/src/main/di/container'

describe('Container (tsyringe)', () => {
  beforeEach(() => {
    container.reset()
  })

  it('resolves a registered value', () => {
    const TOKEN = Symbol('test')
    container.register(TOKEN, { useValue: { value: 42 } })
    expect(container.resolve(TOKEN)).toEqual({ value: 42 })
  })

  it('useValue returns same instance on repeated resolve', () => {
    const TOKEN = Symbol('test')
    const instance = { value: 42 }
    container.register(TOKEN, { useValue: instance })
    const a = container.resolve(TOKEN)
    const b = container.resolve(TOKEN)
    expect(a).toBe(b)
    expect(a.value).toBe(42)
  })

  it('throws for unregistered token', () => {
    expect(() => container.resolve(Symbol('missing'))).toThrow()
  })

  it('isRegistered checks token existence', () => {
    const TOKEN = Symbol('test')
    expect(container.isRegistered(TOKEN)).toBe(false)
    container.register(TOKEN, { useValue: 1 })
    expect(container.isRegistered(TOKEN)).toBe(true)
  })
})
