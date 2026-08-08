import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, describe, expect, it } from 'vitest'
import { scanDirectory } from '../../../desktop/src/main/utils/scan-directory'

const JPG_ONLY = new Set(['.jpg'])

const tempDirs: string[] = []

function makeTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-scan-'))
  tempDirs.push(dir)
  return dir
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('scanDirectory', () => {
  it('returns files with truncated=false when the tree fits under the limit', async () => {
    const dir = makeTempDir()
    fs.writeFileSync(path.join(dir, 'a.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'b.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'notes.txt'), 'x')

    const result = await scanDirectory(dir, { limit: 10, supportedExtensions: JPG_ONLY })

    expect(result.files).toHaveLength(2)
    expect(result.scannedTotal).toBe(2)
    expect(result.truncated).toBe(false)
    expect(result.limit).toBe(10)
  })

  it('keeps counting scannedTotal past the limit and marks the result truncated', async () => {
    const dir = makeTempDir()
    for (let i = 0; i < 5; i++) {
      fs.writeFileSync(path.join(dir, `photo-${i}.jpg`), 'x')
    }

    const result = await scanDirectory(dir, { limit: 3, supportedExtensions: JPG_ONLY })

    expect(result.files).toHaveLength(3)
    expect(result.scannedTotal).toBe(5)
    expect(result.truncated).toBe(true)
    expect(result.limit).toBe(3)
  })

  it('keeps counting across nested directories after the limit is hit', async () => {
    const dir = makeTempDir()
    fs.mkdirSync(path.join(dir, 'sub'))
    fs.writeFileSync(path.join(dir, 'one.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'sub', 'two.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'sub', 'three.jpg'), 'x')

    const result = await scanDirectory(dir, { limit: 2, supportedExtensions: JPG_ONLY })

    expect(result.files).toHaveLength(2)
    expect(result.scannedTotal).toBe(3)
    expect(result.truncated).toBe(true)
  })

  it('does not count files outside the supported extensions', async () => {
    const dir = makeTempDir()
    fs.writeFileSync(path.join(dir, 'a.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'b.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'c.raw'), 'x')

    const result = await scanDirectory(dir, { limit: 2, supportedExtensions: JPG_ONLY })

    expect(result.scannedTotal).toBe(2)
    expect(result.truncated).toBe(false)
  })

  it('rejects a non-directory path with the SCAN_INVALID_DIR error code', async () => {
    const dir = makeTempDir()
    const filePath = path.join(dir, 'a.jpg')
    fs.writeFileSync(filePath, 'x')

    await expect(
      scanDirectory(filePath, { supportedExtensions: JPG_ONLY }),
    ).rejects.toThrow('SCAN_INVALID_DIR')
  })
})
