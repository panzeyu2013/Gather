import { parentPort } from 'worker_threads'
import {
  detectFacesMultiScale,
  initDetector,
  prepareFaceImageFrame,
  releaseDetector,
} from './face-detector'
import {
  encodeFace,
  initEncoder,
  releaseEncoder,
  setEncoderConfig,
} from './face-encoder'

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

parentPort.on('message', async (request: Request) => {
  try {
    if (request.kind === 'init') {
      setEncoderConfig(request.encoderInputSize, request.embeddingDim)
      await initDetector(request.detectorPath, request.provider)
      await initEncoder(request.encoderPath, request.provider, request.threads)
      parentPort!.postMessage({ id: request.id, result: true })
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
