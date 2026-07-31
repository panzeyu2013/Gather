import { afterEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { parseImportDeepLink } from '../../desktop/src/main/deep-link'

const directories: string[] = []
const supported = new Set(['.jpg', '.nef'])

afterEach(() => {
  for (const directory of directories.splice(0)) {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

describe('Capture One import deep links', () => {
  it('accepts supported files with literal percent signs without double decoding', () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-link-'))
    directories.push(directory)
    const filepath = path.join(directory, '100% ready.NEF')
    fs.writeFileSync(filepath, 'raw')
    const encoded = encodeURIComponent(filepath)

    expect(parseImportDeepLink(
      `gather://import?file=${encoded}`,
      supported,
    )).toEqual([filepath])
  })

  it('rejects unsupported, missing, duplicate, and non-import targets', () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-link-'))
    directories.push(directory)
    const jpeg = path.join(directory, 'photo.jpg')
    const text = path.join(directory, 'notes.txt')
    fs.writeFileSync(jpeg, 'jpeg')
    fs.writeFileSync(text, 'text')
    const jpegValue = encodeURIComponent(jpeg)
    const textValue = encodeURIComponent(text)

    expect(parseImportDeepLink(
      `gather://import?file=${jpegValue}&file=${jpegValue}&file=${textValue}&file=${encodeURIComponent(path.join(directory, 'missing.nef'))}`,
      supported,
    )).toEqual([jpeg])
    expect(parseImportDeepLink(
      pathToFileURL(jpeg).toString(),
      supported,
    )).toEqual([])
  })
})
