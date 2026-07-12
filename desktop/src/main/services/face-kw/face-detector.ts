import ort from 'onnxruntime-node'
import sharp from 'sharp'
import { existsSync } from 'fs'
import { SettingsService } from '../settings'
import { resolveExecutionProviders } from './provider'

export interface DetectedFace {
  bbox: [number, number, number, number]
  confidence: number
}

export const INPUT_SIZE = 640

let detectionSession: ort.InferenceSession | null = null

function computeIoU(a: [number, number, number, number], b: [number, number, number, number]): number {
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

  const areaA = aw * ah
  const areaB = bw * bh
  const unionArea = areaA + areaB - interArea

  return unionArea > 0 ? interArea / unionArea : 0
}

function nonMaxSuppression(faces: DetectedFace[], iouThreshold: number, maxDetections: number): DetectedFace[] {
  const sorted = [...faces].sort((a, b) => b.confidence - a.confidence)
  const selected: DetectedFace[] = []

  for (const face of sorted) {
    let keep = true
    for (const sel of selected) {
      if (computeIoU(face.bbox, sel.bbox) > iouThreshold) {
        keep = false
        break
      }
    }
    if (keep) {
      selected.push(face)
      if (selected.length >= maxDetections) break
    }
  }

  return selected
}

export async function initDetector(modelPath: string): Promise<void> {
  if (!existsSync(modelPath)) {
    throw new Error(`Face detector model not found: ${modelPath}`)
  }
  const provider = SettingsService.getInstance().get('onnx_provider', 'auto')
  detectionSession = await ort.InferenceSession.create(modelPath, {
    executionProviders: resolveExecutionProviders(provider),
  })
}

export async function detectFaces(
  imagePath: string,
): Promise<DetectedFace[]> {
  if (!detectionSession) {
    throw new Error('Face detector not initialized. Call initDetector first.')
  }

  const { data, info } = await sharp(imagePath)
    .resize(INPUT_SIZE, INPUT_SIZE, { fit: 'fill' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const channels = info.channels
  const height = info.height
  const width = info.width
  const pixels = height * width
  const input = new Float32Array(3 * height * width)

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const srcIdx = (y * width + x) * channels
      const dstIdx = y * width + x
      input[dstIdx] = data[srcIdx] / 255.0
      input[pixels + dstIdx] = data[srcIdx + 1] / 255.0
      input[2 * pixels + dstIdx] = data[srcIdx + 2] / 255.0
    }
  }

  const tensor = new ort.Tensor('float32', input, [1, 3, height, width])
  const feeds: Record<string, ort.Tensor> = {}
  const inputName = detectionSession.inputNames[0]
  feeds[inputName] = tensor

  const results = await detectionSession.run(feeds)
  const outputName = detectionSession.outputNames[0]
  const output = results[outputName]

  const rawData = output.data as Float32Array
  const shape = output.dims

  const faces: DetectedFace[] = []
  let rawArr: Float32Array

  if (shape.length === 3) {
    rawArr = new Float32Array(rawData.buffer, rawData.byteOffset, shape[1] * shape[2])
  } else if (shape.length === 2) {
    rawArr = rawData
  } else {
    rawArr = rawData
  }

  const numDetections = shape.length === 3 ? shape[1] : shape[0]
  const stride = shape.length === 3 ? shape[2] : shape[1]
  const settings = SettingsService.getInstance()
  const confidenceThreshold = settings.getNumber('detect_confidence', 0.5)
  const nmsThreshold = settings.getNumber('nms_threshold', 0.4)
  const maxDetections = settings.getNumber('max_detections', 100)

  for (let i = 0; i < numDetections; i++) {
    const offset = i * stride
    const confidence = rawArr[offset + 4]
    if (confidence < confidenceThreshold) continue

    const x = rawArr[offset]
    const y = rawArr[offset + 1]
    const w = rawArr[offset + 2]
    const h = rawArr[offset + 3]

    faces.push({
      bbox: [x, y, w, h],
      confidence,
    })
  }

  return nonMaxSuppression(faces, nmsThreshold, maxDetections)
}

export async function releaseDetector(): Promise<void> {
  if (detectionSession) {
    await detectionSession.release()
    detectionSession = null
  }
}
