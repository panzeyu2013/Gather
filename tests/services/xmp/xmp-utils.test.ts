import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import {
  createEmptyXmpDoc,
  parseXmp,
  extractKeywords,
  extractXmpAttributes,
  writeXmpAttributes,
  writeXmpAttributesAsync,
  parseXmpAsync,
  backupXmpFile,
  restoreXmpFile,
} from '../../../desktop/src/main/services/xmp/xmp-utils'
import { XmpSidecarWriter, getXmpSidecarPath } from '../../../desktop/src/main/services/xmp/xmp-sidecar-writer'

function tmpdir() {
  return fs.mkdtempSync(path.join(fs.realpathSync('/tmp'), 'xmp-test-'))
}

function xmpPath(dir: string, name = 'test.xmp') {
  return path.join(dir, name)
}

function photoPath(dir: string, name = 'test.jpg') {
  return path.join(dir, name)
}

function writeFile(filePath: string, content: string) {
  fs.writeFileSync(filePath, content, 'utf-8')
}

function readFile(filePath: string): string {
  return fs.readFileSync(filePath, 'utf-8')
}

function validMinimalXmp(keywords: string[] = ['initial']): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:dc="http://purl.org/dc/elements/1.1/">
      <dc:subject>
        <rdf:Bag>
          ${keywords.map(k => `<rdf:li>${k}</rdf:li>`).join('\n          ')}
        </rdf:Bag>
      </dc:subject>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>`
}

describe('xmp-utils', () => {
  let dir: string

  beforeEach(() => {
    dir = tmpdir()
  })

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true })
  })

  it('scenario 1: createEmptyXmpDoc → write keywords → extractKeywords returns them', () => {
    const xp = xmpPath(dir)
    writeXmpAttributes(xp, { keywords: ['wedding', 'portrait'] })

    const doc = parseXmp(xp)
    expect(doc).not.toBeNull()
    const keywords = extractKeywords(doc!)
    expect(keywords).toEqual(['wedding', 'portrait'])
  })

  it('scenario 2: valid XMP with dc:subject → extractKeywords returns existing keywords', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp(['landscape', 'sunset']))

    const doc = parseXmp(xp)
    expect(doc).not.toBeNull()
    const keywords = extractKeywords(doc!)
    expect(keywords).toEqual(['landscape', 'sunset'])
  })

  it('scenario 3: XMP without dc:subject → writeXmpAttributes creates it', () => {
    const xp = xmpPath(dir)
    const xmpContent = `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="">
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>`
    writeFile(xp, xmpContent)

    writeXmpAttributes(xp, { keywords: ['new-tag'] })

    const doc = parseXmp(xp)
    expect(doc).not.toBeNull()
    const keywords = extractKeywords(doc!)
    expect(keywords).toEqual(['new-tag'])
  })

  it('scenario 4: XML special characters survive round-trip', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    const keywords = ['<test>', 'foo & bar', "it's \"great\""]
    writeXmpAttributes(xp, { keywords })

    const doc = parseXmp(xp)
    const result = extractKeywords(doc!)
    expect(result).toEqual(keywords)
  })

  it('scenario 5: invalid XML → parseXmp returns null', () => {
    const xp = xmpPath(dir)
    writeFile(xp, 'not valid xml <<<')

    const doc = parseXmp(xp)
    expect(doc).toBeNull()
  })

  it('scenario 6: writeXmpAttributes → backupXmpFile → write again → restoreXmpFile restores to backup state', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    writeXmpAttributes(xp, { keywords: ['first'] })
    const backup = backupXmpFile(xp)

    writeXmpAttributes(xp, { keywords: ['second'] })

    restoreXmpFile(xp, backup)

    const doc = parseXmp(xp)
    const keywords = extractKeywords(doc!)
    expect(keywords).toEqual(['first'])
  })

  it('scenario 7: empty file → backupXmpFile copies it, restoreXmpFile handles', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    const backup = backupXmpFile(xp)
    expect(fs.existsSync(backup)).toBe(true)

    restoreXmpFile(xp, backup)
    expect(fs.existsSync(backup)).toBe(false)
  })

  it('scenario 8: Unicode emoji keywords survive round-trip', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    const keywords = ['😀🎉', '日本語テスト', 'café']
    writeXmpAttributes(xp, { keywords })

    const doc = parseXmp(xp)
    const result = extractKeywords(doc!)
    expect(result).toEqual(keywords)
  })

  it('scenario 9: writeXmpAttributes with keywords+rating+dateTaken+GPS → all namespaces present', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    writeXmpAttributes(xp, {
      keywords: ['test'],
      rating: 5,
      dateTaken: '2024-01-15T10:30:00',
      latitude: 35.6895,
      longitude: 139.6917,
    })

    const content = readFile(xp)
    expect(content).toContain('dc:subject')
    expect(content).toContain('xmp:Rating')
    expect(content).toContain('xmp:CreateDate')
    expect(content).toContain('exif:GPSLatitude')
    expect(content).toContain('exif:GPSLongitude')
  })

  it('round-trips rating and color label from a sidecar', () => {
    const xp = xmpPath(dir)
    writeXmpAttributes(xp, {
      keywords: ['selected'],
      rating: 5,
      label: 'Green',
    })

    const doc = parseXmp(xp)
    expect(extractXmpAttributes(doc!)).toEqual({
      keywords: ['selected'],
      rating: 5,
      label: 'Green',
    })
  })

  it('scenario 10: write rating then write keywords → rating preserved', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    writeXmpAttributes(xp, { rating: 4 })
    writeXmpAttributes(xp, { keywords: ['tag1', 'tag2'] })

    const content = readFile(xp)
    expect(content).toContain('xmp:Rating')
    expect(content).toContain('tag1')
  })

  it('scenario 11: restoreXmpFile with non-existent backup path does not crash', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    const originalContent = readFile(xp)

    expect(() => restoreXmpFile(xp, '/nonexistent/path.bak')).not.toThrow()
    expect(readFile(xp)).toBe(originalContent)
  })

  it('scenario 12: backupXmpFile when source does not exist returns path without creating file', () => {
    const xp = xmpPath(dir)
    const backup = backupXmpFile(xp)
    expect(typeof backup).toBe('string')
    expect(fs.existsSync(backup)).toBe(false)
  })

  it('creates isolated backups across repeated writeback transactions', () => {
    const xp = xmpPath(dir)
    writeXmpAttributes(xp, { keywords: ['original'] })
    const backup = backupXmpFile(xp)
    writeXmpAttributes(xp, { keywords: ['first-write'] })
    const secondBackup = backupXmpFile(xp)
    expect(secondBackup).not.toBe(backup)
    expect(extractKeywords(parseXmp(secondBackup)!)).toEqual(['first-write'])
    restoreXmpFile(xp, backup)

    expect(extractKeywords(parseXmp(xp)!)).toEqual(['original'])
  })

  it('scenario 13: long keywords string (5000 chars) survives round-trip', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp([]))

    const longKeyword = 'a'.repeat(5000)
    writeXmpAttributes(xp, { keywords: [longKeyword] })

    const doc = parseXmp(xp)
    const result = extractKeywords(doc!)
    expect(result).toEqual([longKeyword])
  })

  it('writes sidecars asynchronously with atomic replacement', async () => {
    const xp = xmpPath(dir)
    await writeXmpAttributesAsync(xp, {
      keywords: ['async'],
      rating: 5,
      label: 'Green',
    })

    const doc = await parseXmpAsync(xp)
    expect(extractXmpAttributes(doc!)).toEqual({
      keywords: ['async'],
      rating: 5,
      label: 'Green',
    })
    expect(fs.readdirSync(dir).filter(file => file.includes('.tmp-'))).toEqual([])
  })
})

describe('XmpSidecarWriter', () => {
  let dir: string

  beforeEach(() => {
    dir = tmpdir()
  })

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true })
  })

  it('scenario 14: writeAttributes → readKeywords returns written keywords', async () => {
    const pp = photoPath(dir)
    const writer = new XmpSidecarWriter()

    await writer.writeAttributes(pp, { keywords: ['sidecar-test', 'tag2'] })

    const keywords = await writer.readKeywords(pp)
    expect(keywords).toEqual(['sidecar-test', 'tag2'])

    const xp = getXmpSidecarPath(pp)
    expect(fs.existsSync(xp)).toBe(true)
  })

  it('uses the Capture One basename sidecar convention', () => {
    expect(getXmpSidecarPath(path.join(dir, 'IMG_0001.NEF')))
      .toBe(path.join(dir, 'IMG_0001.xmp'))
  })
})
