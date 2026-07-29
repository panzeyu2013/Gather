import * as ort from 'onnxruntime-node'
import sharp from 'sharp'
import { existsSync } from 'fs'
import { resolveExecutionProviders, resolveModelPath } from './provider'
import { MODEL_CONFIG } from './model-config'
import type { FaceImageFrame, FaceLandmarks } from './face-detector'
import { heavyTaskScheduler } from '../../utils/heavy-task-scheduler'

let encodingSession: ort.InferenceSession | null = null
let encoderInputSize: number = MODEL_CONFIG.encode.inputSize
let embeddingDim: number = MODEL_CONFIG.encode.embeddingDim
let encoderModelPath = ''
let encoderThreads = 4
let encoderFallbackAvailable = false

export function setEncoderConfig(inputSize: number, dim: number): void {
  encoderInputSize = inputSize
  embeddingDim = dim
}

export async function initEncoder(
  modelPath: string,
  onnxProvider: string,
  threads: number,
): Promise<void> {
  const resolved = resolveModelPath(modelPath)
  if (!existsSync(resolved)) {
    throw new Error(`Face encoder model not found: ${resolved}`)
  }
  const executionProviders = resolveExecutionProviders(onnxProvider)
  encodingSession = await ort.InferenceSession.create(resolved, {
    executionProviders,
    intraOpNumThreads: threads,
  })
  encoderModelPath = resolved
  encoderThreads = threads
  encoderFallbackAvailable = executionProviders.some(provider => provider !== 'cpu')
}

async function runEncoder(tensor: ort.Tensor) {
  return heavyTaskScheduler.run(async () => {
    if (!encodingSession) {
      throw new Error('Face encoder not initialized. Call initEncoder first.')
    }
    try {
      return await encodingSession.run({ [encodingSession.inputNames[0]]: tensor })
    } catch (error) {
      if (!encoderFallbackAvailable || !encoderModelPath) throw error
      console.warn('Accelerated face encoding failed; retrying with CPU', error)
      await encodingSession.release()
      encodingSession = await ort.InferenceSession.create(encoderModelPath, {
        executionProviders: ['cpu'],
        intraOpNumThreads: encoderThreads,
      })
      encoderFallbackAvailable = false
      return encodingSession.run({ [encodingSession.inputNames[0]]: tensor })
    }
  }, 1)
}

interface SimilarityTransform {
  a: number
  b: number
  tx: number
  ty: number
}

const ARCFACE_TEMPLATE: FaceLandmarks = [
  [38.2946, 51.6963],
  [73.5318, 51.5014],
  [56.0252, 71.7366],
  [41.5493, 92.3655],
  [70.7299, 92.2041],
]

export function estimateSimilarityTransform(
  source: FaceLandmarks,
  destination: FaceLandmarks,
): SimilarityTransform {
  const sourceMean = source.reduce(
    (sum, point) => [sum[0] + point[0], sum[1] + point[1]],
    [0, 0],
  ).map((value) => value / source.length)
  const destinationMean = destination.reduce(
    (sum, point) => [sum[0] + point[0], sum[1] + point[1]],
    [0, 0],
  ).map((value) => value / destination.length)

  let denominator = 0
  let real = 0
  let imaginary = 0
  for (let index = 0; index < source.length; index++) {
    const sx = source[index][0] - sourceMean[0]
    const sy = source[index][1] - sourceMean[1]
    const dx = destination[index][0] - destinationMean[0]
    const dy = destination[index][1] - destinationMean[1]
    denominator += sx * sx + sy * sy
    real += sx * dx + sy * dy
    imaginary += sx * dy - sy * dx
  }
  if (denominator <= Number.EPSILON) {
    throw new Error('Face landmarks are degenerate')
  }

  const a = real / denominator
  const b = imaginary / denominator
  return {
    a,
    b,
    tx: destinationMean[0] - a * sourceMean[0] + b * sourceMean[1],
    ty: destinationMean[1] - b * sourceMean[0] - a * sourceMean[1],
  }
}

function sampleBilinear(
  data: Buffer,
  width: number,
  height: number,
  channels: number,
  x: number,
  y: number,
  channel: number,
): number {
  if (x < 0 || y < 0 || x > width - 1 || y > height - 1) return 0
  const x0 = Math.floor(x)
  const y0 = Math.floor(y)
  const x1 = Math.min(width - 1, x0 + 1)
  const y1 = Math.min(height - 1, y0 + 1)
  const wx = x - x0
  const wy = y - y0
  const at = (px: number, py: number) => data[(py * width + px) * channels + channel]
  return (
    at(x0, y0) * (1 - wx) * (1 - wy) +
    at(x1, y0) * wx * (1 - wy) +
    at(x0, y1) * (1 - wx) * wy +
    at(x1, y1) * wx * wy
  )
}

function alignedArcFaceInput(
  data: Buffer,
  width: number,
  height: number,
  channels: number,
  landmarks: FaceLandmarks,
  size: number,
): Float32Array {
  const templateScale = size / 112
  const destination = ARCFACE_TEMPLATE.map(([x, y]) => [
    x * templateScale,
    y * templateScale,
  ]) as FaceLandmarks
  const transform = estimateSimilarityTransform(landmarks, destination)
  const determinant = transform.a * transform.a + transform.b * transform.b
  if (determinant <= Number.EPSILON) {
    throw new Error('Face alignment transform is singular')
  }

  const planeSize = size * size
  const input = new Float32Array(planeSize * 3)
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = x - transform.tx
      const dy = y - transform.ty
      const sourceX = (transform.a * dx + transform.b * dy) / determinant
      const sourceY = (-transform.b * dx + transform.a * dy) / determinant
      const destinationIndex = y * size + x
      for (let channel = 0; channel < 3; channel++) {
        const pixel = sampleBilinear(
          data,
          width,
          height,
          channels,
          sourceX,
          sourceY,
          channel,
        )
        input[channel * planeSize + destinationIndex] = (pixel - 127.5) / 127.5
      }
    }
  }
  return input
}

async function fallbackCropInput(
  imageBuffer: Buffer,
  bbox: [number, number, number, number],
  size: number,
): Promise<Float32Array> {
  const metadata = await sharp(imageBuffer).metadata()
  const imageWidth = metadata.width ?? 0
  const imageHeight = metadata.height ?? 0
  if (imageWidth <= 0 || imageHeight <= 0) {
    throw new Error('Could not determine image dimensions for face encoding')
  }

  const [xNorm, yNorm, widthNorm, heightNorm] = bbox
  const centerX = (xNorm + widthNorm / 2) * imageWidth
  const centerY = (yNorm + heightNorm / 2) * imageHeight
  const cropSize = Math.max(widthNorm * imageWidth, heightNorm * imageHeight) * 1.25
  const left = Math.max(0, Math.floor(centerX - cropSize / 2))
  const top = Math.max(0, Math.floor(centerY - cropSize / 2))
  const width = Math.min(imageWidth - left, Math.max(1, Math.ceil(cropSize)))
  const height = Math.min(imageHeight - top, Math.max(1, Math.ceil(cropSize)))
  const { data } = await sharp(imageBuffer)
    .extract({ left, top, width, height })
    .resize(size, size, { fit: 'cover' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const planeSize = size * size
  const input = new Float32Array(planeSize * 3)
  for (let index = 0; index < planeSize; index++) {
    for (let channel = 0; channel < 3; channel++) {
      input[channel * planeSize + index] = (data[index * 3 + channel] - 127.5) / 127.5
    }
  }
  return input
}

export async function encodeFace(
  image: Buffer | FaceImageFrame,
  bbox: [number, number, number, number],
  normalizedLandmarks?: FaceLandmarks,
): Promise<number[]> {
  if (!encodingSession) {
    throw new Error('Face encoder not initialized. Call initEncoder first.')
  }

  const size = encoderInputSize
  let input: Float32Array
  if (normalizedLandmarks) {
    const frame = Buffer.isBuffer(image)
      ? await sharp(image).removeAlpha().raw().toBuffer({ resolveWithObject: true })
      : {
          data: image.data,
          info: {
            width: image.width,
            height: image.height,
            channels: image.channels,
          },
        }
    const pixelLandmarks = normalizedLandmarks.map(([x, y]) => [
      x * frame.info.width,
      y * frame.info.height,
    ]) as FaceLandmarks
    input = alignedArcFaceInput(
      frame.data,
      frame.info.width,
      frame.info.height,
      frame.info.channels,
      pixelLandmarks,
      size,
    )
  } else {
    if (!Buffer.isBuffer(image)) {
      const encoded = await sharp(image.data, {
        raw: {
          width: image.width,
          height: image.height,
          channels: image.channels as 1 | 2 | 3 | 4,
        },
      }).jpeg().toBuffer()
      input = await fallbackCropInput(encoded, bbox, size)
    } else {
      input = await fallbackCropInput(image, bbox, size)
    }
  }

  const tensor = new ort.Tensor('float32', input, [1, 3, size, size])
  const results = await runEncoder(tensor)
  const rawData = results[encodingSession.outputNames[0]].data as Float32Array
  if (rawData.length !== embeddingDim) {
    throw new Error(
      `Unexpected ArcFace embedding length: expected ${embeddingDim}, received ${rawData.length}`,
    )
  }

  const norm = Math.sqrt(rawData.reduce((sum, value) => sum + value * value, 0))
  if (!Number.isFinite(norm) || norm <= Number.EPSILON) {
    throw new Error('ArcFace returned an invalid embedding')
  }
  return Array.from(rawData, (value) => value / norm)
}

export async function releaseEncoder(): Promise<void> {
  if (encodingSession) {
    await encodingSession.release()
    encodingSession = null
  }
  encoderModelPath = ''
  encoderFallbackAvailable = false
}
