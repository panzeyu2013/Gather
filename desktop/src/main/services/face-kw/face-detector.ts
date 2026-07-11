import ort from 'onnxruntime-node'
import sharp from 'sharp'

export interface DetectedFace {
  bbox: [number, number, number, number]
  confidence: number
}

const INPUT_SIZE = 640
let detectionSession: ort.InferenceSession | null = null

export async function initDetector(modelPath: string): Promise<void> {
  detectionSession = await ort.InferenceSession.create(modelPath, {
    executionProviders: ['CoreMLExecutionProvider', 'CPUExecutionProvider'],
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

  for (let i = 0; i < numDetections; i++) {
    const offset = i * stride
    const confidence = rawArr[offset + 4]
    if (confidence < 0.5) continue

    const x = rawArr[offset]
    const y = rawArr[offset + 1]
    const w = rawArr[offset + 2]
    const h = rawArr[offset + 3]

    faces.push({
      bbox: [x, y, w, h],
      confidence,
    })
  }

  return faces
}

export async function releaseDetector(): Promise<void> {
  if (detectionSession) {
    await detectionSession.release()
    detectionSession = null
  }
}
