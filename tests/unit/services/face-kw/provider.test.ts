import { describe, expect, it } from 'vitest'
import { resolveExecutionProviders } from '../../../../desktop/src/main/services/face-kw/provider'

describe('resolveExecutionProviders', () => {
  it('auto on darwin prefers coreml with cpu fallback', () => {
    expect(resolveExecutionProviders('auto', 'darwin')).toEqual(['coreml', 'cpu'])
  })

  it('auto on win32 prefers dml with cpu fallback', () => {
    expect(resolveExecutionProviders('auto', 'win32')).toEqual(['dml', 'cpu'])
  })

  it('auto on other platforms stays on cpu', () => {
    expect(resolveExecutionProviders('auto', 'linux')).toEqual(['cpu'])
  })

  it('honors an explicit provider choice with cpu fallback', () => {
    expect(resolveExecutionProviders('coreml', 'darwin')).toEqual(['coreml', 'cpu'])
    expect(resolveExecutionProviders('dml', 'win32')).toEqual(['dml', 'cpu'])
    expect(resolveExecutionProviders('cuda', 'linux')).toEqual(['cuda', 'cpu'])
  })

  it('honors an explicit cpu choice without fallback duplication', () => {
    expect(resolveExecutionProviders('cpu', 'darwin')).toEqual(['cpu'])
    expect(resolveExecutionProviders('cpu', 'win32')).toEqual(['cpu'])
  })

  it('normalizes provider aliases', () => {
    expect(resolveExecutionProviders('CoreMLExecutionProvider', 'darwin')).toEqual(['coreml', 'cpu'])
    expect(resolveExecutionProviders('DmlExecutionProvider', 'win32')).toEqual(['dml', 'cpu'])
  })
})
