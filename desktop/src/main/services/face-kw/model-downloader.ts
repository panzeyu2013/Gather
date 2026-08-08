import { createWriteStream } from 'fs'
import { access, copyFile, mkdir, rename, rm } from 'fs/promises'
import { join } from 'path'
import { execFile } from 'child_process'
import { promisify } from 'util'
import { tmpdir } from 'os'
import { getModelResourcesDir } from './provider'
import { MODEL_CONFIG } from './model-config'
import { isValidOnnxModel } from './onnx-validator'

export interface DownloadProgress {
  filename: string
  percent: number
  downloaded: number
  total: number
  /** Stage code instead of natural-language copy (design_improvements.md
   * 4.4.2): set only on milestone events (e.g. `models.installed`). */
  phase?: string
}

const { packageUrl, fileMap: EXTRACT_MAP } = MODEL_CONFIG.download
const execFileAsync = promisify(execFile)

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath)
    return true
  } catch {
    return false
  }
}

/**
 * A model file counts as installed only when it is a structurally valid, non-
 * empty ONNX file. A zero-byte, truncated, or otherwise corrupt leftover from
 * an interrupted download must never satisfy the presence check, or the
 * installer would skip re-downloading forever.
 */
async function validModelFile(filePath: string): Promise<boolean> {
  return isValidOnnxModel(filePath)
}

async function downloadFile(url: string, dest: string, onProgress: (p: DownloadProgress) => void): Promise<void> {
  // fetch follows redirects by default and permits https -> http downgrades,
  // which would let a MITM replace the model package. Follow redirects
  // manually and reject any hop that leaves HTTPS.
  let currentUrl = url
  for (let hop = 0; hop < 8; hop++) {
    const response = await fetch(currentUrl, { redirect: 'manual' })
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get('location')
      if (!location) throw new Error(`Model download redirect without Location: ${currentUrl}`)
      const next = new URL(location, currentUrl)
      if (next.protocol !== 'https:') {
        throw new Error(`Model download must stay on HTTPS, refused: ${next.protocol}//${next.host}`)
      }
      currentUrl = next.toString()
      continue
    }
    if (!response.ok || !response.body) throw new Error(`Download failed (${response.status}): ${url}`)
    await writeResponseToFile(response, dest, onProgress)
    return
  }
  throw new Error(`Model download exceeded redirect limit: ${url}`)
}

async function writeResponseToFile(
  response: Response,
  dest: string,
  onProgress: (p: DownloadProgress) => void,
): Promise<void> {
  const total = parseInt(response.headers.get('content-length') || '0', 10)
  let downloaded = 0
  const reader = response.body!.getReader()
  const writeStream = createWriteStream(dest)

  await new Promise<void>((resolve, reject) => {
    // Attach the error listener immediately: an unhandled 'error' event on the
    // stream (disk full, permission denied, interrupted write) would otherwise
    // crash the main process.
    writeStream.once('error', reject)
    writeStream.once('finish', resolve)
    void (async () => {
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          if (!writeStream.write(Buffer.from(value))) {
            await new Promise<void>((ack, fail) => {
              writeStream.once('drain', ack)
              writeStream.once('error', fail)
            })
          }
          downloaded += value.length
          const filename = dest.split('/').pop() || ''
          onProgress({ filename, percent: total > 0 ? (downloaded / total) * 100 : 0, downloaded, total })
        }
        writeStream.end()
      } catch (error) {
        await reader.cancel().catch(() => undefined)
        writeStream.destroy(error instanceof Error ? error : new Error(String(error)))
      }
    })()
  })
}

async function unzipFile(zipPath: string, destDir: string): Promise<void> {
  try {
    await execFileAsync('tar', ['-xf', zipPath, '-C', destDir])
  } catch {
    try {
      await execFileAsync('unzip', ['-o', zipPath, '-d', destDir])
    } catch {
      throw new Error('Failed to extract model files. Please ensure "unzip" or "tar" is available on your system.')
    }
  }
}

export async function downloadDefaultModels(
  getUrl: (key: string) => string,
  onProgress: (progress: DownloadProgress) => void,
): Promise<void> {
  const targetDir = getModelResourcesDir()
  await mkdir(targetDir, { recursive: true })

  const needsDetector = !(await validModelFile(join(targetDir, 'face_detector.onnx')))
  const needsEncoder = !(await validModelFile(join(targetDir, 'face_encoder.onnx')))
  if (!needsDetector && !needsEncoder) return

  const url = getUrl('model_download_url') || packageUrl

  // Download ZIP to temp
  const nonce = `${process.pid}-${Date.now()}`
  const tmpZip = join(tmpdir(), `gather-models-${nonce}.zip`)
  const tmpExtract = join(tmpdir(), `gather-models-extract-${nonce}`)
  try {
    onProgress({ filename: 'buffalo_l.zip', percent: 0, downloaded: 0, total: 0 })
    await downloadFile(url, tmpZip, onProgress)

    // Extract to temp dir
    await mkdir(tmpExtract, { recursive: true })
    await unzipFile(tmpZip, tmpExtract)

    // Copy required ONNX files to target. Each missing file is written to a
    // temporary sibling and atomically renamed into place, so an interrupted
    // copy never leaves a truncated file at the final model path.
    for (const [srcName, destName] of Object.entries(EXTRACT_MAP)) {
      const src = join(tmpExtract, srcName)
      const dest = join(targetDir, destName)
      if (!(await pathExists(src)) || await validModelFile(dest)) continue
      const tmpDest = join(targetDir, `.${destName}.tmp-${nonce}`)
      try {
        await copyFile(src, tmpDest)
        await rename(tmpDest, dest)
      } catch (error) {
        await rm(tmpDest, { force: true })
        throw error
      }
    }

    if (!(await validModelFile(join(targetDir, 'face_detector.onnx')))) {
      throw new Error('FACE_MODEL_DETECTOR_CORRUPT')
    }
    if (!(await validModelFile(join(targetDir, 'face_encoder.onnx')))) {
      throw new Error('FACE_MODEL_ENCODER_CORRUPT')
    }

    // A final 100% event means the models are installed, not merely downloaded.
    onProgress({ filename: '', percent: 100, downloaded: 0, total: 0, phase: 'models.installed' })
  } catch (err) {
    throw err
  } finally {
    await Promise.allSettled([
      rm(tmpZip, { force: true }),
      rm(tmpExtract, { force: true, recursive: true }),
    ])
  }
}
