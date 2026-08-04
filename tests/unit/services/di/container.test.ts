import { describe, it, expect, beforeEach } from 'vitest'
import { container, DI_TOKENS } from '../../../../desktop/src/main/di/container'

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

  it('DI_TOKENS contains all expected symbols', () => {
    expect(DI_TOKENS.DB).toBeDefined()
    expect(DI_TOKENS.PHOTO_REPO).toBeDefined()
    expect(DI_TOKENS.SESSION_REPO).toBeDefined()
    expect(DI_TOKENS.FACE_REPO).toBeDefined()
    expect(DI_TOKENS.PERSON_REPO).toBeDefined()
    expect(DI_TOKENS.CULLING_DECISION_REPO).toBeDefined()
    expect(DI_TOKENS.SIMILARITY_RESULT_REPO).toBeDefined()
    expect(DI_TOKENS.WRITEBACK_REPO).toBeDefined()
    expect(DI_TOKENS.METADATA_OUTBOX_REPO).toBeDefined()
    expect(DI_TOKENS.METADATA_CACHE_REPO).toBeDefined()
    expect(DI_TOKENS.SMART_ALBUM_REPO).toBeDefined()
    expect(DI_TOKENS.SETTINGS_REPO).toBeDefined()
    expect(DI_TOKENS.SETTINGS_SERVICE).toBeDefined()
    expect(DI_TOKENS.SESSION_SERVICE).toBeDefined()
    expect(DI_TOKENS.FACE_KW_SERVICE).toBeDefined()
    expect(DI_TOKENS.SIMILARITY_SERVICE).toBeDefined()
    expect(DI_TOKENS.IMAGE_SERVICE).toBeDefined()
    expect(DI_TOKENS.FILTER_ENGINE).toBeDefined()
    expect(DI_TOKENS.WRITER_ROUTER).toBeDefined()
    expect(DI_TOKENS.METADATA_SYNC_COORDINATOR).toBeDefined()
  })
})
