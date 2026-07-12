import { describe, it, expect } from 'vitest'

describe('Container', () => {
  it('resolves a registered singleton', async () => {
    const { Container } = await import('../../../desktop/src/main/di/container')
    const c = new Container()
    const TOKEN = Symbol('test')
    const factory = () => ({ value: 42 })
    c.register(TOKEN, factory)
    expect(c.resolve(TOKEN)).toEqual({ value: 42 })
  })

  it('returns the same instance on repeated resolve (singleton)', async () => {
    const { Container } = await import('../../../desktop/src/main/di/container')
    const c = new Container()
    const TOKEN = Symbol('test')
    let count = 0
    c.register(TOKEN, () => ({ count: ++count }))
    const a = c.resolve(TOKEN)
    const b = c.resolve(TOKEN)
    expect(a).toBe(b)
    expect(a.count).toBe(1)
  })

  it('throws for unregistered token', async () => {
    const { Container } = await import('../../../desktop/src/main/di/container')
    const c = new Container()
    expect(() => c.resolve(Symbol('missing'))).toThrow()
  })

  it('reset clears cached instances', async () => {
    const { Container } = await import('../../../desktop/src/main/di/container')
    const c = new Container()
    const TOKEN = Symbol('test')
    let count = 0
    c.register(TOKEN, () => ({ count: ++count }))
    const a = c.resolve(TOKEN)
    expect(a.count).toBe(1)
    c.reset()
    const b = c.resolve(TOKEN)
    expect(b.count).toBe(2)
    expect(a).not.toBe(b)
  })
})
