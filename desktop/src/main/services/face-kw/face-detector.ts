import ort from 'onnxruntime-node'
import sharp from 'sharp'
import { existsSync } from 'fs'
import { SettingsService } from '../settings'
import { resolveExecutionProviders, resolveModelPath } from './provider'
import { MODEL_CONFIG } from './model-config'

export interface DetectedFace {
  bbox: [number, number, number, number]
  confidence: number
}

let detectionSession: ort.InferenceSession | null = null

function getInputSize(): number {
  return SettingsService.getInstance().getNumber('detect_input_size', MODEL_CONFIG.detect.inputSize)
}

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

// ── SCRFD anchor helpers ──

interface Anchor {
  cx: number
  cy: number
}

function generateAnchors(inputSize: number): { anchors: Anchor[]; stride: number }[] {
  const { strides, anchorScales } = MODEL_CONFIG.detect
  const levels: { anchors: Anchor[]; stride: number }[] = []

  for (const stride of strides) {
    const featSize = Math.ceil(inputSize / stride)
    const anchors: Anchor[] = []
    for (const scale of anchorScales) {
      for (let i = 0; i < featSize; i++) {
        for (let j = 0; j < featSize; j++) {
          anchors.push({ cx: (j + 0.5) * stride, cy: (i + 0.5) * stride })
        }
      }
    }
    levels.push({ anchors, stride })
  }

  return levels
}

// ── Detection ──

export async function initDetector(modelPath: string): Promise<void> {
  const resolved = resolveModelPath(modelPath)
  if (!existsSync(resolved)) {
    throw new Error(`Face detector model not found: ${resolved}`)
  }
  const provider = SettingsService.getInstance().get('onnx_provider', 'auto')
  detectionSession = await ort.InferenceSession.create(resolved, {
    executionProviders: resolveExecutionProviders(provider),
  })
}

function isScrfdMultiScale(outputNames: readonly string[]): boolean {
  return outputNames.some((n) => /^score_\d+$/.test(n))
}

function isScrfdBatch(outputNames: readonly string[]): boolean {
  return outputNames.some((n) => n === 'scores' || n === 'score' || n === 'output')
}

export async function detectFaces(imagePath: string): Promise<DetectedFace[]> {
  if (!detectionSession) {
    throw new Error('Face detector not initialized. Call initDetector first.')
  }

  const size = getInputSize()
  const { data, info } = await sharp(imagePath)
    .resize(size, size, { fit: 'fill' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const channels = info.channels
  const height = info.height
  const width = info.width
  const pixels = height * width
  const input = new Float32Array(3 * pixels)

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
  feeds[detectionSession.inputNames[0]] = tensor
  const results = await detectionSession.run(feeds)
  const outputNames = detectionSession.outputNames
  const settings = SettingsService.getInstance()
  const confidenceThreshold = settings.getNumber('detect_confidence', 0.5)
  const nmsThreshold = settings.getNumber('nms_threshold', 0.4)
  const maxDetections = settings.getNumber('max_detections', 100)

  if (isScrfdMultiScale(outputNames)) {
    return detectScrfdMultiScale(results, outputNames, size, confidenceThreshold, nmsThreshold, maxDetections)
  }
  if (isScrfdBatch(outputNames)) {
    return detectScrfdBatch(results, outputNames, size, confidenceThreshold, nmsThreshold, maxDetections)
  }
  return detectLegacy(results, outputNames, confidenceThreshold, nmsThreshold, maxDetections)
}

// ── SCRFD multi-scale (stride-specific outputs) ──

function detectScrfdMultiScale(
  results: Record<string, ort.Tensor>,
  outputNames: readonly string[],
  inputSize: number,
  confThresh: number,
  iouThresh: number,
  maxDet: number,
): DetectedFace[] {
  const faces: DetectedFace[] = []
  const { strides } = MODEL_CONFIG.detect

  for (const stride of strides) {
    const scoreName = outputNames.find((n) => n === `score_${stride}`)
    const bboxName = outputNames.find((n) => n === `bbox_${stride}`)
    if (!scoreName || !bboxName) continue

    const scores = results[scoreName].data as Float32Array
    const bboxes = results[bboxName].data as Float32Array
    const scoreShape = results[scoreName].dims
    const bboxShape = results[bboxName].dims
    const numAnchors = scoreShape.length === 3 ? scoreShape[1] : scoreShape[0]
    const scoreStride = scoreShape.length === 3 ? scoreShape[2] : 1

    const featSize = Math.ceil(inputSize / stride)
    const anchorsPerCell = numAnchors / (featSize * featSize)

    let anchorIdx = 0
    for (let i = 0; i < featSize; i++) {
      for (let j = 0; j < featSize; j++) {
        for (let k = 0; k < anchorsPerCell; k++) {
          const s = scoreStride > 1 ? scores[anchorIdx * scoreStride] : scores[anchorIdx]
          if (s < confThresh) { anchorIdx++; continue }

          const bo = anchorIdx * 4
          const cx = (j + 0.5) * stride
          const cy = (i + 0.5) * stride
          const x1 = Math.max(0, cx - bboxes[bo] * stride)
          const y1 = Math.max(0, cy - bboxes[bo + 1] * stride)
          const x2 = Math.min(inputSize, cx + bboxes[bo + 2] * stride)
          const y2 = Math.min(inputSize, cy + bboxes[bo + 3] * stride)

          faces.push({ bbox: [x1, y1, x2 - x1, y2 - y1], confidence: s })
          anchorIdx++
        }
      }
    }
  }

  return nonMaxSuppression(faces, iouThresh, maxDet)
}

// ── SCRFD batch mode (single scores/bboxes tensors) ──

function detectScrfdBatch(
  results: Record<string, ort.Tensor>,
  outputNames: readonly string[],
  inputSize: number,
  confThresh: number,
  iouThresh: number,
  maxDet: number,
): DetectedFace[] {
  const scoreName = outputNames.find((n) => n === 'scores' || n === 'score')!
  const bboxName = outputNames.find((n) => n === 'bboxes' || n === 'bbox')!
  const scores = results[scoreName].data as Float32Array
  const bboxes = results[bboxName].data as Float32Array
  const scoreShape = results[scoreName].dims
  const numAnchors = scoreShape.length === 3 ? scoreShape[1] : scoreShape[0]

  const levels = generateAnchors(inputSize)
  const faces: DetectedFace[] = []
  let anchorIdx = 0

  for (const level of levels) {
    for (const anchor of level.anchors) {
      if (anchorIdx >= numAnchors) break
      let s: number
      if (scoreShape.length === 3 && scoreShape[2] > 1) {
        s = scores[anchorIdx * scoreShape[2]]
      } else {
        s = scores[anchorIdx]
      }

      if (s >= confThresh) {
        const bo = anchorIdx * 4
        const x1 = Math.max(0, anchor.cx - bboxes[bo] * level.stride)
        const y1 = Math.max(0, anchor.cy - bboxes[bo + 1] * level.stride)
        const x2 = Math.min(inputSize, anchor.cx + bboxes[bo + 2] * level.stride)
        const y2 = Math.min(inputSize, anchor.cy + bboxes[bo + 3] * level.stride)
        faces.push({ bbox: [x1, y1, x2 - x1, y2 - y1], confidence: s })
      }
      anchorIdx++
    }
  }

  return nonMaxSuppression(faces, iouThresh, maxDet)
}

// ── Legacy single-tensor format (RetinaFace) ──

function detectLegacy(
  results: Record<string, ort.Tensor>,
  outputNames: readonly string[],
  confThresh: number,
  iouThresh: number,
  maxDet: number,
): DetectedFace[] {
  const output = results[outputNames[0]]
  const rawData = output.data as Float32Array
  const shape = output.dims
  const faces: DetectedFace[] = []

  let rawArr: Float32Array
  if (shape.length === 3) {
    rawArr = new Float32Array(rawData.buffer, rawData.byteOffset, shape[1] * shape[2])
  } else {
    rawArr = rawData
  }

  const numDetections = shape.length === 3 ? shape[1] : shape[0]
  const stride = shape.length === 3 ? shape[2] : shape[1]

  for (let i = 0; i < numDetections; i++) {
    const offset = i * stride
    const confidence = rawArr[offset + 4]
    if (confidence < confThresh) continue
    faces.push({
      bbox: [rawArr[offset], rawArr[offset + 1], rawArr[offset + 2], rawArr[offset + 3]],
      confidence,
    })
  }

  return nonMaxSuppression(faces, iouThresh, maxDet)
}

export async function releaseDetector(): Promise<void> {
  if (detectionSession) {
    await detectionSession.release()
    detectionSession = null
  }
}
