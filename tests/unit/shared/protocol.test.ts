
import fs from 'fs'
import path from 'path'
import {
  ALLOWED_COMMANDS,
  ALLOWED_EVENTS,
  DESTRUCTIVE_COMMANDS,
  isRecord,
} from '../../../packages/shared/src/protocol'

function readPreloadSet(name: string): Set<string> {
  const desktopRoot = path.basename(process.cwd()) === 'desktop'
    ? process.cwd()
    : path.resolve(process.cwd(), 'desktop')
  const source = fs.readFileSync(
    path.join(desktopRoot, 'src/preload/index.ts'),
    'utf8',
  )
  const declaration = `const ${name} = new Set<`
  const declarationStart = source.indexOf(declaration)
  const valuesStart = source.indexOf('[', declarationStart)
  const valuesEnd = source.indexOf('])', valuesStart)
  if (declarationStart < 0 || valuesStart < 0 || valuesEnd < 0) {
    throw new Error(`Missing preload set ${name}`)
  }
  const block = source.slice(valuesStart + 1, valuesEnd)
  return new Set([...block.matchAll(/'([^']+)'/g)].map(match => match[1]))
}
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

  it('keeps sandboxed preload command policy synchronized with the shared protocol', () => {
    expect(readPreloadSet('ALLOWED_COMMANDS')).toEqual(ALLOWED_COMMANDS)
    expect(readPreloadSet('DESTRUCTIVE_COMMANDS')).toEqual(DESTRUCTIVE_COMMANDS)
    expect(readPreloadSet('ALLOWED_EVENTS')).toEqual(ALLOWED_EVENTS)
  })
})
