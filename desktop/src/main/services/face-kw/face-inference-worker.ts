import { parentPort } from 'worker_threads'
import {
  detectFacesMultiScale,
  initDetector,
  prepareFaceImageFrame,
  releaseDetector,
  type FaceImageFrame,
} from './face-detector'
import {
  encodeFace,
  initEncoder,
  releaseEncoder,
  setEncoderConfig,
} from './face-encoder'
import { initDetectorWithFallback } from './face-inference-fallback'
import { MODEL_CONFIG } from './model-config'

type Request =
  | {
      id: number
      kind: 'init'
      detectorPath: string
      encoderPath: string
      provider: string
      threads: number
      encoderInputSize: number
      embeddingDim: number
    }
  | {
      id: number
      kind: 'analyze'
      image: Uint8Array
      inputSizes: number[]
      confidenceThreshold: number
      nmsThreshold: number
      maxDetections: number
      embeddingDim: number
    }
  | { id: number; kind: 'shutdown' }

if (!parentPort) throw new Error('face-inference-worker must run in a worker thread')

// Dummy gray frame for the init-time warmup run. Executing the full detector
// once exercises the dynamic-output path before any real photo is analyzed,
// so an accelerated EP that cannot actually run SCRFD is caught here and the
// session is rebuilt on CPU instead of failing mid-analysis.
function buildWarmupFrame(inputSize: number): FaceImageFrame {
  return {
    data: Buffer.alloc(inputSize * inputSize * 3, 128),
    width: inputSize,
    height: inputSize,
    channels: 3,
  }
}

parentPort.on('message', async (request: Request) => {
  try {
    if (request.kind === 'init') {
      setEncoderConfig(request.encoderInputSize, request.embeddingDim)
      const report = await initDetectorWithFallback(
        request.detectorPath,
        request.provider,
        {
          createSession: (modelPath, provider) => initDetector(modelPath, provider),
          warmup: () => detectFacesMultiScale(
            buildWarmupFrame(MODEL_CONFIG.detect.inputSize),
            [MODEL_CONFIG.detect.inputSize],
            0.99,
            0.4,
            1,
          ).then(() => undefined),
        },
      )
      await initEncoder(request.encoderPath, request.provider, request.threads)
      parentPort!.postMessage({
        id: request.id,
        result: { provider: report.provider, fallbackUsed: report.fallbackUsed },
      })
      return
    }
    if (request.kind === 'shutdown') {
      await Promise.allSettled([releaseDetector(), releaseEncoder()])
      parentPort!.postMessage({ id: request.id, result: true })
      return
    }

    const frame = await prepareFaceImageFrame(Buffer.from(request.image))
    const faces = await detectFacesMultiScale(
      frame,
      request.inputSizes,
      request.confidenceThreshold,
      request.nmsThreshold,
      request.maxDetections,
    )
    const observations = []
    let encodingFailures = 0
    for (const face of faces) {
      let embedding = new Array(request.embeddingDim).fill(0)
      try {
        embedding = await encodeFace(frame, face.bbox, face.landmarks)
      } catch {
        encodingFailures++
      }
      observations.push({
        bbox: face.bbox,
        confidence: face.confidence,
        embedding,
      })
    }
    parentPort!.postMessage({
      id: request.id,
      result: { observations, encodingFailures },
    })
  } catch (error) {
    parentPort!.postMessage({
      id: request.id,
      error: error instanceof Error ? error.message : String(error),
    })
  }
})
