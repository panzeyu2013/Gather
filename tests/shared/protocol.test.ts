
import { ALLOWED_EVENTS, isRecord } from '../../packages/shared/src/protocol'
describe('shared protocol runtime guards', () => {
  it('accepts only plain command parameter objects', () => {
    expect(isRecord({ session_id: 's1' })).toBe(true)
    expect(isRecord(Object.create(null))).toBe(true)
    expect(isRecord(null)).toBe(false)
    expect(isRecord(['not', 'params'])).toBe(false)
    expect(isRecord('session.list')).toBe(false)
  })

  it('keeps the preload event surface explicit', () => {
    expect(ALLOWED_EVENTS.has('progress')).toBe(true)
    expect(ALLOWED_EVENTS.has('engine:status')).toBe(true)
    expect(ALLOWED_EVENTS.has('c1:import-trigger')).toBe(true)
    expect(ALLOWED_EVENTS.has('unknown:event')).toBe(false)
  })
})
