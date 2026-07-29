import * as ort from 'onnxruntime-node'
import sharp from 'sharp'
import { existsSync } from 'fs'
import { resolveDetectorExecutionProviders, resolveModelPath } from './provider'
import { heavyTaskScheduler } from '../../utils/heavy-task-scheduler'

export type FaceLandmarks = [
  [number, number],
  [number, number],
  [number, number],
  [number, number],
  [number, number],
]

export interface DetectedFace {
  /** Normalized x, y, width and height in the original image. */
  bbox: [number, number, number, number]
  /** Five normalized SCRFD landmarks: eyes, nose and mouth corners. */
  landmarks?: FaceLandmarks
  confidence: number
}

export interface FaceImageFrame {
  data: Buffer
  width: number
  height: number
  channels: number
}

interface PixelFace {
  bbox: [number, number, number, number]
  landmarks?: FaceLandmarks
  confidence: number
}

interface ScrfdLayout {
  featureMaps: number
  strides: number[]
  anchorsPerCell: number
  hasLandmarks: boolean
}

let detectionSession: ort.InferenceSession | null = null
let detectionModelPath = ''
let detectorFallbackAvailable = false

export async function initDetector(modelPath: string, onnxProvider: string): Promise<void> {
  const resolved = resolveModelPath(modelPath)
  if (!existsSync(resolved)) {
    throw new Error(`Face detector model not found: ${resolved}`)
  }
  const executionProviders = resolveDetectorExecutionProviders(onnxProvider)
  detectionSession = await ort.InferenceSession.create(resolved, {
    executionProviders,
  })
  detectionModelPath = resolved
  detectorFallbackAvailable = executionProviders.some(provider => provider !== 'cpu')
}

async function runDetector(tensor: ort.Tensor) {
  return heavyTaskScheduler.run(async () => {
    if (!detectionSession) {
      throw new Error('Face detector not initialized. Call initDetector first.')
    }
    const feeds = { [detectionSession.inputNames[0]]: tensor }
    try {
      return await detectionSession.run(feeds)
    } catch (error) {
      if (!detectorFallbackAvailable || !detectionModelPath) throw error
      console.warn('Accelerated face detection failed; retrying with CPU', error)
      await detectionSession.release()
      detectionSession = await ort.InferenceSession.create(detectionModelPath, {
        executionProviders: ['cpu'],
      })
      detectorFallbackAvailable = false
      return detectionSession.run({ [detectionSession.inputNames[0]]: tensor })
    }
  }, 1)
}

function computeIoU(
  a: [number, number, number, number],
  b: [number, number, number, number],
): number {
  const [ax1, ay1, aw, ah] = a
  const [bx1, by1, bw, bh] = b
  const ax2 = ax1 + aw
  const ay2 = ay1 + ah
  const bx2 = bx1 + bw
  const by2 = by1 + bh
  const interX1 = Math.max(ax1, bx1)
  const interY1 = Math.max(ay1, by1)
  const interX2 = Math.min(ax2, bx2)
  const interY2 = Math.min(ay2, by2)
  const interW = Math.max(0, interX2 - interX1)
  const interH = Math.max(0, interY2 - interY1)
  const interArea = interW * interH
  const unionArea = aw * ah + bw * bh - interArea
  return unionArea > 0 ? interArea / unionArea : 0
}

function nonMaxSuppression(
  faces: PixelFace[],
  iouThreshold: number,
  maxDetections: number,
): PixelFace[] {
  const sorted = [...faces].sort((a, b) => b.confidence - a.confidence)
  const selected: PixelFace[] = []
  for (const face of sorted) {
    if (selected.every((other) => computeIoU(face.bbox, other.bbox) <= iouThreshold)) {
      selected.push(face)
      if (selected.length >= maxDetections) break
    }
  }
  return selected
}

export function resolveScrfdLayout(outputCount: number): ScrfdLayout {
  if (outputCount === 6) {
    return { featureMaps: 3, strides: [8, 16, 32], anchorsPerCell: 2, hasLandmarks: false }
  }
  if (outputCount === 9) {
    return { featureMaps: 3, strides: [8, 16, 32], anchorsPerCell: 2, hasLandmarks: true }
  }
  if (outputCount === 10) {
    return { featureMaps: 5, strides: [8, 16, 32, 64, 128], anchorsPerCell: 1, hasLandmarks: false }
  }
  if (outputCount === 15) {
    return { featureMaps: 5, strides: [8, 16, 32, 64, 128], anchorsPerCell: 1, hasLandmarks: true }
  }
  throw new Error(
    `Unsupported SCRFD output signature: expected 6, 9, 10 or 15 tensors, received ${outputCount}`,
  )
}

function tensorRows(tensor: ort.Tensor, columns: number): number {
  const length = tensor.data.length
  if (length % columns !== 0) {
    throw new Error(`Invalid SCRFD tensor shape ${tensor.dims.join('x')} for ${columns} columns`)
  }
  return length / columns
}

function scoreAt(tensor: ort.Tensor, row: number, rows: number): number {
  const data = tensor.data as Float32Array
  const columns = data.length / rows
  if (columns === 1) return data[row]
  // Some exported detectors retain the two-class score tensor.
  return data[row * columns + columns - 1]
}

function decodeScrfd(
  tensors: ort.Tensor[],
  inputSize: number,
  confidenceThreshold: number,
): PixelFace[] {
  const layout = resolveScrfdLayout(tensors.length)
  const faces: PixelFace[] = []

  for (let level = 0; level < layout.featureMaps; level++) {
    const stride = layout.strides[level]
    const scoreTensor = tensors[level]
    const bboxTensor = tensors[level + layout.featureMaps]
    const landmarkTensor = layout.hasLandmarks
      ? tensors[level + layout.featureMaps * 2]
      : undefined
    const bboxRows = tensorRows(bboxTensor, 4)
    const landmarkRows = landmarkTensor ? tensorRows(landmarkTensor, 10) : bboxRows
    const expectedRows =
      Math.ceil(inputSize / stride) *
      Math.ceil(inputSize / stride) *
      layout.anchorsPerCell

    if (bboxRows !== expectedRows || landmarkRows !== expectedRows) {
      throw new Error(
        `SCRFD stride ${stride} returned ${bboxRows} anchors; expected ${expectedRows}`,
      )
    }

    const bboxData = bboxTensor.data as Float32Array
    const landmarkData = landmarkTensor?.data as Float32Array | undefined
    const featureWidth = Math.ceil(inputSize / stride)

    for (let row = 0; row < expectedRows; row++) {
      const confidence = scoreAt(scoreTensor, row, expectedRows)
      if (confidence < confidenceThreshold) continue

      // InsightFace repeats each cell for every anchor before moving to the next cell.
      const cell = Math.floor(row / layout.anchorsPerCell)
      const cx = (cell % featureWidth) * stride
      const cy = Math.floor(cell / featureWidth) * stride
      const offset = row * 4
      const x1 = Math.max(0, cx - bboxData[offset] * stride)
      const y1 = Math.max(0, cy - bboxData[offset + 1] * stride)
      const x2 = Math.min(inputSize, cx + bboxData[offset + 2] * stride)
      const y2 = Math.min(inputSize, cy + bboxData[offset + 3] * stride)

      let landmarks: FaceLandmarks | undefined
      if (landmarkData) {
        landmarks = Array.from({ length: 5 }, (_, point) => [
          cx + landmarkData[row * 10 + point * 2] * stride,
          cy + landmarkData[row * 10 + point * 2 + 1] * stride,
        ]) as FaceLandmarks
      }
      faces.push({
        bbox: [x1, y1, Math.max(0, x2 - x1), Math.max(0, y2 - y1)],
        landmarks,
        confidence,
      })
    }
  }
  return faces
}

export async function detectFaces(
  image: Buffer | FaceImageFrame,
  inputSize: number,
  confidenceThreshold: number,
  nmsThreshold: number,
  maxDetections: number,
): Promise<DetectedFace[]> {
  if (!detectionSession) {
    throw new Error('Face detector not initialized. Call initDetector first.')
  }

  const frame = Buffer.isBuffer(image) ? await prepareFaceImageFrame(image) : image
  const originalWidth = frame.width
  const originalHeight = frame.height
  if (originalWidth <= 0 || originalHeight <= 0) {
    throw new Error('Could not determine image dimensions for face detection')
  }

  const scale = Math.min(inputSize / originalWidth, inputSize / originalHeight)
  const resizedWidth = Math.max(1, Math.round(originalWidth * scale))
  const resizedHeight = Math.max(1, Math.round(originalHeight * scale))
  const { data, info } = await sharp(frame.data, {
    raw: {
      width: frame.width,
      height: frame.height,
      channels: frame.channels as 1 | 2 | 3 | 4,
    },
  })
    .resize(resizedWidth, resizedHeight, { fit: 'fill' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const planeSize = inputSize * inputSize
  const input = new Float32Array(3 * planeSize)
  // The zero-filled canvas represents the same black padding used by InsightFace.
  input.fill((0 - 127.5) / 128)
  for (let y = 0; y < resizedHeight; y++) {
    for (let x = 0; x < resizedWidth; x++) {
      const source = (y * resizedWidth + x) * info.channels
      const destination = y * inputSize + x
      input[destination] = (data[source] - 127.5) / 128
      input[planeSize + destination] = (data[source + 1] - 127.5) / 128
      input[planeSize * 2 + destination] = (data[source + 2] - 127.5) / 128
    }
  }

  const tensor = new ort.Tensor('float32', input, [1, 3, inputSize, inputSize])
  const results = await runDetector(tensor)
  const tensors = detectionSession.outputNames.map((name) => results[name])
  const decoded = decodeScrfd(tensors, inputSize, confidenceThreshold)
  const selected = nonMaxSuppression(decoded, nmsThreshold, maxDetections)

  return selected.map((face) => {
    const x1 = Math.max(0, Math.min(originalWidth, face.bbox[0] / scale))
    const y1 = Math.max(0, Math.min(originalHeight, face.bbox[1] / scale))
    const x2 = Math.max(x1, Math.min(originalWidth, (face.bbox[0] + face.bbox[2]) / scale))
    const y2 = Math.max(y1, Math.min(originalHeight, (face.bbox[1] + face.bbox[3]) / scale))
    return {
      bbox: [
        x1 / originalWidth,
        y1 / originalHeight,
        (x2 - x1) / originalWidth,
        (y2 - y1) / originalHeight,
      ],
      landmarks: face.landmarks?.map(([x, y]) => [
        Math.max(0, Math.min(1, x / scale / originalWidth)),
        Math.max(0, Math.min(1, y / scale / originalHeight)),
      ]) as FaceLandmarks | undefined,
      confidence: face.confidence,
    }
  })
}

export async function detectFacesMultiScale(
  image: Buffer | FaceImageFrame,
  inputSizes: number[],
  confidenceThreshold: number,
  nmsThreshold: number,
  maxDetections: number,
): Promise<DetectedFace[]> {
  const sizes = [...new Set(
    inputSizes
      .map((size) => Math.floor(size))
      .filter((size) => size >= 32 && size % 32 === 0),
  )].sort((a, b) => a - b)
  if (sizes.length === 0) {
    throw new Error('At least one SCRFD input size divisible by 32 is required')
  }

  const frame = Buffer.isBuffer(image) ? await prepareFaceImageFrame(image) : image
  const detections: DetectedFace[] = []
  for (const size of sizes) {
    detections.push(...await detectFaces(
      frame,
      size,
      confidenceThreshold,
      nmsThreshold,
      maxDetections,
    ))
  }
  return nonMaxSuppression(detections, nmsThreshold, maxDetections)
}

export async function prepareFaceImageFrame(imageBuffer: Buffer): Promise<FaceImageFrame> {
  const { data, info } = await sharp(imageBuffer)
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })
  if (info.width <= 0 || info.height <= 0) {
    throw new Error('Could not decode image pixels for face analysis')
  }
  return {
    data,
    width: info.width,
    height: info.height,
    channels: info.channels,
  }
}

export async function releaseDetector(): Promise<void> {
  if (detectionSession) {
    await detectionSession.release()
    detectionSession = null
  }
  detectionModelPath = ''
  detectorFallbackAvailable = false
}
