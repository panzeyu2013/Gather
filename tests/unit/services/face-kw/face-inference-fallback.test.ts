import { describe, expect, it, vi } from 'vitest'
import { initDetectorWithFallback } from '../../../../desktop/src/main/services/face-kw/face-inference-fallback'

function makeDeps(overrides: {
  create?: (modelPath: string, provider: string) => Promise<void>
  warmup?: () => Promise<void>
}) {
  const createSession = vi.fn(overrides.create ?? (async () => undefined))
  const warmup = vi.fn(overrides.warmup ?? (async () => undefined))
  return { createSession, warmup }
}

describe('initDetectorWithFallback', () => {
  it('keeps the requested provider when creation and warmup succeed', async () => {
    const deps = makeDeps({})
    const report = await initDetectorWithFallback('det.onnx', 'auto', deps)
    // The exact first provider depends on the platform; provider resolution
    // itself is covered by provider.test.ts. Here only the no-fallback
    // contract matters.
    expect(report.fallbackUsed).toBe(false)
    expect(typeof report.provider).toBe('string')
    expect(report.provider.length).toBeGreaterThan(0)
    expect(deps.createSession).toHaveBeenCalledTimes(1)
    expect(deps.createSession).toHaveBeenCalledWith('det.onnx', 'auto')
    expect(deps.warmup).toHaveBeenCalledTimes(1)
  })

  it('rebuilds on cpu when session creation fails on the accelerated path', async () => {
    const deps = makeDeps({
      create: async (_path, provider) => {
        if (provider !== 'cpu') throw new Error('CoreML EP failed to load')
      },
    })
    const report = await initDetectorWithFallback('det.onnx', 'auto', deps)
    expect(report).toEqual({ provider: 'cpu', fallbackUsed: true })
    expect(deps.createSession).toHaveBeenCalledTimes(2)
    expect(deps.createSession).toHaveBeenLastCalledWith('det.onnx', 'cpu')
    expect(deps.warmup).not.toHaveBeenCalled()
  })

  it('rebuilds on cpu when the warmup run fails (SCRFD dynamic-output symptom)', async () => {
    const deps = makeDeps({
      warmup: async () => {
        throw new Error('ONNX Runtime error ... unsupported dynamic output shape')
      },
    })
    const report = await initDetectorWithFallback('det.onnx', 'auto', deps)
    expect(report).toEqual({ provider: 'cpu', fallbackUsed: true })
    expect(deps.createSession).toHaveBeenCalledTimes(2)
    expect(deps.createSession).toHaveBeenLastCalledWith('det.onnx', 'cpu')
    expect(deps.warmup).toHaveBeenCalledTimes(1)
  })

  it('does not warm up a rebuilt cpu session', async () => {
    const deps = makeDeps({
      warmup: async () => {
        throw new Error('coreml run failure')
      },
    })
    const report = await initDetectorWithFallback('det.onnx', 'auto', deps)
    expect(report.fallbackUsed).toBe(true)
    expect(deps.warmup).toHaveBeenCalledTimes(1)
  })

  it('explicit cpu skips the accelerated attempt entirely', async () => {
    const deps = makeDeps({})
    const report = await initDetectorWithFallback('det.onnx', 'cpu', deps)
    expect(report).toEqual({ provider: 'cpu', fallbackUsed: false })
    expect(deps.createSession).toHaveBeenCalledTimes(1)
    expect(deps.createSession).toHaveBeenCalledWith('det.onnx', 'cpu')
    expect(deps.warmup).not.toHaveBeenCalled()
  })

  it('explicit accelerated choice still gets the cpu fallback', async () => {
    const deps = makeDeps({
      create: async (_path, provider) => {
        if (provider !== 'cpu') throw new Error('no coreml')
      },
    })
    const report = await initDetectorWithFallback('det.onnx', 'coreml', deps)
    expect(report).toEqual({ provider: 'cpu', fallbackUsed: true })
    expect(deps.createSession).toHaveBeenNthCalledWith(1, 'det.onnx', 'coreml')
    expect(deps.createSession).toHaveBeenNthCalledWith(2, 'det.onnx', 'cpu')
  })

  it('propagates failure when the cpu rebuild also fails', async () => {
    const deps = makeDeps({
      create: async () => {
        throw new Error('model corrupt')
      },
    })
    await expect(initDetectorWithFallback('det.onnx', 'auto', deps)).rejects.toThrow('model corrupt')
    expect(deps.createSession).toHaveBeenCalledTimes(2)
  })

  it('reports the resolved first provider when no fallback is needed', async () => {
    const deps = makeDeps({})
    const report = await initDetectorWithFallback('det.onnx', 'coreml', deps)
    expect(report.provider).toBe('coreml')
    expect(report.fallbackUsed).toBe(false)
  })
})
