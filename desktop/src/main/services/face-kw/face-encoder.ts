import ort from 'onnxruntime-node'
import sharp from 'sharp'
import { SettingsService } from '../settings'

let encodingSession: ort.InferenceSession | null = null

export async function initEncoder(modelPath: string): Promise<void> {
  const provider = SettingsService.getInstance().get('onnx_provider', 'CoreMLExecutionProvider')
  const executionProviders = provider === 'CPU'
    ? ['CPUExecutionProvider']
    : provider === 'CUDA'
      ? ['CUDAExecutionProvider', 'CPUExecutionProvider']
      : ['CoreMLExecutionProvider', 'CPUExecutionProvider']
  encodingSession = await ort.InferenceSession.create(modelPath, {
    executionProviders,
  })
}

export async function encodeFace(
  imagePath: string,
  bbox: [number, number, number, number],
): Promise<number[]> {
  if (!encodingSession) {
    throw new Error('Face encoder not initialized. Call initEncoder first.')
  }

  const ENCODER_INPUT_SIZE = SettingsService.getInstance().getNumber('encoder_input_size', 112)
  const EMBEDDING_DIM = SettingsService.getInstance().getNumber('embedding_dim', 128)

  const originalMeta = await sharp(imagePath).metadata()
  const imgWidth = originalMeta.width ?? 0
  const imgHeight = originalMeta.height ?? 0

  const [xNorm, yNorm, wNorm, hNorm] = bbox

  const x = Math.max(0, Math.floor(xNorm * imgWidth))
  const y = Math.max(0, Math.floor(yNorm * imgHeight))
  const w = Math.min(imgWidth - x, Math.ceil(wNorm * imgWidth))
  const h = Math.min(imgHeight - y, Math.ceil(hNorm * imgHeight))

  const { data } = await sharp(imagePath)
    .extract({ left: x, top: y, width: w, height: h })
    .resize(ENCODER_INPUT_SIZE, ENCODER_INPUT_SIZE, { fit: 'cover' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const pixels = ENCODER_INPUT_SIZE * ENCODER_INPUT_SIZE
  const input = new Float32Array(3 * pixels)

  for (let i = 0; i < pixels; i++) {
    const srcIdx = i * 3
    input[i] = data[srcIdx] / 255.0
    input[pixels + i] = data[srcIdx + 1] / 255.0
    input[2 * pixels + i] = data[srcIdx + 2] / 255.0
  }

  const tensor = new ort.Tensor('float32', input, [1, 3, ENCODER_INPUT_SIZE, ENCODER_INPUT_SIZE])
  const feeds: Record<string, ort.Tensor> = {}
  const inputName = encodingSession.inputNames[0]
  feeds[inputName] = tensor

  const results = await encodingSession.run(feeds)
  const outputName = encodingSession.outputNames[0]
  const output = results[outputName]
  const rawData = output.data as Float32Array

  const embedding: number[] = []
  const len = Math.min(rawData.length, EMBEDDING_DIM)
  for (let i = 0; i < len; i++) {
    embedding.push(rawData[i])
  }

  while (embedding.length < EMBEDDING_DIM) {
    embedding.push(0)
  }

  return embedding
}

export async function releaseEncoder(): Promise<void> {
  if (encodingSession) {
    await encodingSession.release()
    encodingSession = null
  }
}
