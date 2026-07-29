import { createWriteStream } from 'fs'
import { access, copyFile, mkdir, rm } from 'fs/promises'
import { join } from 'path'
import { execFile } from 'child_process'
import { promisify } from 'util'
import { tmpdir } from 'os'
import { getModelResourcesDir } from './provider'
import { MODEL_CONFIG } from './model-config'

export interface DownloadProgress {
  filename: string
  percent: number
  downloaded: number
  total: number
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

async function downloadFile(url: string, dest: string, onProgress: (p: DownloadProgress) => void): Promise<void> {
  const response = await fetch(url)
  if (!response.ok || !response.body) throw new Error(`Download failed (${response.status}): ${url}`)

  const total = parseInt(response.headers.get('content-length') || '0', 10)
  let downloaded = 0
  const reader = response.body.getReader()

  const writeStream = createWriteStream(dest)

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      writeStream.write(Buffer.from(value))
      downloaded += value.length
      const filename = dest.split('/').pop() || ''
      onProgress({ filename, percent: total > 0 ? (downloaded / total) * 100 : 0, downloaded, total })
    }
  } finally {
    writeStream.end()
    await new Promise<void>((resolve, reject) => {
      writeStream.on('finish', resolve)
      writeStream.on('error', reject)
    })
  }
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

  const needsDetector = !(await pathExists(join(targetDir, 'face_detector.onnx')))
  const needsEncoder = !(await pathExists(join(targetDir, 'face_encoder.onnx')))
  if (!needsDetector && !needsEncoder) return

  const url = getUrl('model_download_url') || packageUrl

  // Download ZIP to temp
  const tmpZip = join(tmpdir(), `gather-models-${Date.now()}.zip`)
  try {
    onProgress({ filename: 'buffalo_l.zip', percent: 0, downloaded: 0, total: 0 })
    await downloadFile(url, tmpZip, onProgress)

    onProgress({ filename: 'buffalo_l.zip', percent: 100, downloaded: 0, total: 0 })

    // Extract to temp dir
    const tmpExtract = join(tmpdir(), `gather-models-extract-${Date.now()}`)
    await mkdir(tmpExtract, { recursive: true })
    await unzipFile(tmpZip, tmpExtract)

    // Copy required ONNX files to target
    for (const [srcName, destName] of Object.entries(EXTRACT_MAP)) {
      const src = join(tmpExtract, srcName)
      if (await pathExists(src)) {
        const dest = join(targetDir, destName)
        await copyFile(src, dest)
      }
    }

    if (!(await pathExists(join(targetDir, 'face_detector.onnx')))) {
      throw new Error('Downloaded package does not contain face_detector.onnx')
    }
    if (!(await pathExists(join(targetDir, 'face_encoder.onnx')))) {
      throw new Error('Downloaded package does not contain face_encoder.onnx')
    }

    // Cleanup
    try {
      await rm(tmpZip, { force: true })
      await rm(tmpExtract, { force: true, recursive: true })
    } catch { /* ignore cleanup errors */ }
  } catch (err) {
    try {
      await rm(tmpZip, { force: true })
    } catch { /* ignore */ }
    throw err
  }
}
