import { createWriteStream, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { join } from 'path'
import { execFileSync } from 'child_process'
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

function unzipFile(zipPath: string, destDir: string): void {
  try {
    execFileSync('tar', ['-xf', zipPath, '-C', destDir])
  } catch {
    try {
      execFileSync('unzip', ['-o', zipPath, '-d', destDir])
    } catch {
      throw new Error('无法解压模型文件，请确保系统安装了 unzip 或 tar 命令')
    }
  }
}

export async function downloadDefaultModels(
  getUrl: (key: string) => string,
  onProgress: (progress: DownloadProgress) => void,
): Promise<void> {
  const targetDir = getModelResourcesDir()
  if (!existsSync(targetDir)) mkdirSync(targetDir, { recursive: true })

  const needsDetector = !existsSync(join(targetDir, 'face_detector.onnx'))
  const needsEncoder = !existsSync(join(targetDir, 'face_encoder.onnx'))
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
    mkdirSync(tmpExtract, { recursive: true })
    unzipFile(tmpZip, tmpExtract)

    // Copy required ONNX files to target
    for (const [srcName, destName] of Object.entries(EXTRACT_MAP)) {
      const src = join(tmpExtract, srcName)
      if (existsSync(src)) {
        const dest = join(targetDir, destName)
        writeFileSync(dest, readFileSync(src))
      }
    }

    // Cleanup
    try {
      rmSync(tmpZip, { force: true })
      rmSync(tmpExtract, { force: true, recursive: true })
    } catch { /* ignore cleanup errors */ }
  } catch (err) {
    try {
      rmSync(tmpZip, { force: true })
    } catch { /* ignore */ }
    throw err
  }
}
