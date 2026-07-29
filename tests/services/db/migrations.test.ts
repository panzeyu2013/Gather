import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  app: {
    getPath: () => os.tmpdir(),
  },
}))

import { writeMigratedFaceThumbnail } from '../../../desktop/src/main/db/migrations'

const tempDirs: string[] = []

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('face thumbnail migration', () => {
  it('writes the decoded thumbnail before returning its database path', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-thumb-'))
    tempDirs.push(dir)
    const source = Buffer.from('thumbnail bytes')

    const fileName = writeMigratedFaceThumbnail(
      dir,
      17,
      source.toString('base64'),
    )

    expect(fileName).toBe('17.jpg')
    expect(fs.readFileSync(path.join(dir, fileName))).toEqual(source)
    expect(fs.readdirSync(dir)).toEqual(['17.jpg'])
  })

  it('does not leave a partial file when the destination is unavailable', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-thumb-'))
    tempDirs.push(dir)
    const missingDir = path.join(dir, 'missing')

    expect(() =>
      writeMigratedFaceThumbnail(
        missingDir,
        18,
        Buffer.from('thumbnail bytes').toString('base64'),
      ),
    ).toThrow()
    expect(fs.existsSync(path.join(missingDir, '18.jpg'))).toBe(false)
  })
})
