import ort from 'onnxruntime-node'
import sharp from 'sharp'
import { existsSync } from 'fs'
import { SettingsService } from '../settings'
import { resolveExecutionProviders, resolveModelPath } from './provider'
import { MODEL_CONFIG } from './model-config'

let encodingSession: ort.InferenceSession | null = null

function getEncoderInputSize(): number {
  return SettingsService.getInstance().getNumber('encoder_input_size', MODEL_CONFIG.encode.inputSize)
}

function getEmbeddingDim(): number {
  return SettingsService.getInstance().getNumber('embedding_dim', MODEL_CONFIG.encode.embeddingDim)
}

export async function initEncoder(modelPath: string): Promise<void> {
  const resolved = resolveModelPath(modelPath)
  if (!existsSync(resolved)) {
    throw new Error(`Face encoder model not found: ${resolved}`)
  }
  const provider = SettingsService.getInstance().get('onnx_provider', 'auto')
  const threads = SettingsService.getInstance().getNumber('onnx_threads', 4)
  encodingSession = await ort.InferenceSession.create(resolved, {
    executionProviders: resolveExecutionProviders(provider),
    intraOpNumThreads: threads,
  })
}

export async function encodeFace(
  imagePath: string,
  bbox: [number, number, number, number],
): Promise<number[]> {
  if (!encodingSession) {
    throw new Error('Face encoder not initialized. Call initEncoder first.')
  }

  const originalMeta = await sharp(imagePath).metadata()
  const imgWidth = originalMeta.width ?? 0
  const imgHeight = originalMeta.height ?? 0

  const [xNorm, yNorm, wNorm, hNorm] = bbox

  const x = Math.max(0, Math.floor(xNorm * imgWidth))
  const y = Math.max(0, Math.floor(yNorm * imgHeight))
  const w = Math.min(imgWidth - x, Math.ceil(wNorm * imgWidth))
  const h = Math.min(imgHeight - y, Math.ceil(hNorm * imgHeight))

  const eis = getEncoderInputSize()
  const { data } = await sharp(imagePath)
    .extract({ left: x, top: y, width: w, height: h })
    .resize(eis, eis, { fit: 'cover' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })

  const pixels = eis * eis
  const input = new Float32Array(3 * pixels)

  for (let i = 0; i < pixels; i++) {
    const srcIdx = i * 3
    input[i] = data[srcIdx] / 255.0
    input[pixels + i] = data[srcIdx + 1] / 255.0
    input[2 * pixels + i] = data[srcIdx + 2] / 255.0
  }

  const tensor = new ort.Tensor('float32', input, [1, 3, eis, eis])
  const feeds: Record<string, ort.Tensor> = {}
  const inputName = encodingSession.inputNames[0]
  feeds[inputName] = tensor

  const results = await encodingSession.run(feeds)
  const outputName = encodingSession.outputNames[0]
  const output = results[outputName]
  const rawData = output.data as Float32Array

  const ed = getEmbeddingDim()
  const embedding: number[] = []
  const len = Math.min(rawData.length, ed)
  for (let i = 0; i < len; i++) {
    embedding.push(rawData[i])
  }

  while (embedding.length < ed) {
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
