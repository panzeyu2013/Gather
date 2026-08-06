import { resolveDetectorExecutionProviders } from './provider'

export interface DetectorInitReport {
  /** Final provider used for the detector session ('coreml' | 'cpu' | ...). */
  provider: string
  /** True when the requested path failed and the session was rebuilt on CPU. */
  fallbackUsed: boolean
}

export interface DetectorInitDeps {
  /**
   * Create the ONNX inference session for the given provider string (the
   * worker wires this to face-detector.initDetector, which resolves provider
   * lists itself). Throws on session-creation failure.
   */
  createSession: (modelPath: string, provider: string) => Promise<void>
  /**
   * Execute one full detector run (worker wires this to a dummy-image
   * detection at the smallest SCRFD input size). Throws when the provider
   * cannot actually execute the model — the typical symptom of CoreML
   * failing on SCRFD's dynamic spatial outputs.
   */
  warmup: () => Promise<void>
}

/**
 * Initialize the face detector with graceful degradation:
 *  1. create the session with the requested provider ('auto' resolves to
 *     [coreml, cpu] on macOS, [dml, cpu] on Windows);
 *  2. if creation fails, rebuild with 'cpu';
 *  3. if creation succeeded but the warmup run fails, rebuild with 'cpu';
 *  4. report the effective provider so callers can surface it.
 * Explicit 'cpu' requests skip all of this and fail hard on a broken model.
 */
export async function initDetectorWithFallback(
  modelPath: string,
  requestedProvider: string,
  deps: DetectorInitDeps,
): Promise<DetectorInitReport> {
  const explicit = requestedProvider !== 'auto'
  if (explicit && requestedProvider === 'cpu') {
    await deps.createSession(modelPath, 'cpu')
    return { provider: 'cpu', fallbackUsed: false }
  }

  const firstProvider = explicit ? requestedProvider : 'auto'
  try {
    await deps.createSession(modelPath, firstProvider)
  } catch (error) {
    // Session creation failed on the accelerated path (e.g. the CoreML
    // framework cannot load this build). Rebuild on CPU.
    console.warn(
      `Face detector session creation failed for provider '${firstProvider}' ` +
        `(${error instanceof Error ? error.message : String(error)}); retrying with CPU`,
    )
    await deps.createSession(modelPath, 'cpu')
    return { provider: 'cpu', fallbackUsed: true }
  }

  try {
    await deps.warmup()
  } catch (error) {
    // Session created but the model cannot actually be executed (SCRFD's
    // dynamic outputs are rejected by CoreML at run time). Rebuild on CPU.
    console.warn(
      `Face detector warmup run failed for provider '${firstProvider}' ` +
        `(${error instanceof Error ? error.message : String(error)}); retrying with CPU`,
    )
    try {
      await deps.createSession(modelPath, 'cpu')
    } catch (rebuildError) {
      throw rebuildError
    }
    return { provider: 'cpu', fallbackUsed: true }
  }

  return { provider: resolveDetectorExecutionProviders(firstProvider)[0], fallbackUsed: false }
}
