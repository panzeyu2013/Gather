import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import {
  parseXmp,
  extractKeywords,
  extractXmpAttributes,
  writeXmpAttributes,
  writeXmpAttributesAsync,
  parseXmpAsync,
  backupXmpFile,
  restoreXmpFile,
} from '../../../../desktop/src/main/services/xmp/xmp-utils'
import { XmpSidecarWriter, getXmpSidecarPath } from '../../../../desktop/src/main/services/xmp/xmp-sidecar-writer'

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

  it('scenario 7: empty file → backupXmpFile copies it, restoreXmpFile restores', () => {
    const xp = xmpPath(dir)
    writeFile(xp, '')

    const backup = backupXmpFile(xp)
    expect(fs.existsSync(backup)).toBe(true)
    expect(readFile(backup)).toBe('')

    restoreXmpFile(xp, backup)
    expect(fs.existsSync(backup)).toBe(false)
    expect(readFile(xp)).toBe('')
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

  it('preserves numeric and boolean-looking keywords as lexical text', () => {
    const xp = xmpPath(dir)
    writeFile(xp, validMinimalXmp(['00123', 'true', '1e3']))

    expect(extractKeywords(parseXmp(xp)!)).toEqual(['00123', 'true', '1e3'])
  })

  it('scenario 9: writes standard keywords, rating, original date and GPS fields', () => {
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
    expect(content).toContain('exif:DateTimeOriginal')
    expect(content).not.toContain('xmp:CreateDate')
    expect(content).toContain('exif:GPSLatitude')
    expect(content).toContain('exif:GPSLongitude')
    expect(content).toContain('35,41.37N')
    expect(content).toContain('139,41.502E')

    expect(extractXmpAttributes(parseXmp(xp)!)).toEqual({
      keywords: ['test'],
      rating: 5,
      dateTaken: '2024-01-15T10:30:00',
      latitude: 35.6895,
      longitude: 139.6917,
    })
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
    const content = readFile(xp)
    expect(content).toContain('photoshop:Urgency')
    expect(content).toContain('>2</photoshop:Urgency>')
  })

  it('reads and replaces compact RDF attributes without duplicate properties', () => {
    const xp = xmpPath(dir)
    writeFile(xp, `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmp:Rating="3"
      xmp:Label="Yellow" />
  </rdf:RDF>
</x:xmpmeta>`)

    expect(extractXmpAttributes(parseXmp(xp)!)).toEqual({
      keywords: [],
      rating: 3,
      label: 'Yellow',
    })

    writeXmpAttributes(xp, { rating: 5, label: 'Green' })

    const content = readFile(xp)
    expect(content).not.toContain('xmp:Rating="3"')
    expect(content).not.toContain('xmp:Label="Yellow"')
    expect(content.match(/xmp:Rating/g)).toHaveLength(2)
    expect(content.match(/xmp:Label/g)).toHaveLength(2)
    expect(extractXmpAttributes(parseXmp(xp)!)).toEqual({
      keywords: [],
      rating: 5,
      label: 'Green',
    })
  })

  it('creates a description when an existing RDF container is empty', () => {
    const xp = xmpPath(dir)
    writeFile(xp, `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF>
</x:xmpmeta>`)

    writeXmpAttributes(xp, { keywords: ['created'], rating: 4 })

    expect(extractXmpAttributes(parseXmp(xp)!)).toEqual({
      keywords: ['created'],
      rating: 4,
    })
  })

  it('falls back to Capture One urgency when xmp:Label is absent', () => {
    const xp = xmpPath(dir)
    writeFile(xp, `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
      photoshop:Urgency="1" />
  </rdf:RDF>
</x:xmpmeta>`)

    expect(extractXmpAttributes(parseXmp(xp)!)).toEqual({
      keywords: [],
      label: 'Red',
    })
  })

  it('rejects values outside the interoperable XMP contracts', () => {
    const xp = xmpPath(dir)

    expect(() => writeXmpAttributes(xp, { rating: 6 })).toThrow(/rating/)
    expect(() => writeXmpAttributes(xp, {
      latitude: 91,
      longitude: 120,
    })).toThrow(/latitude/)
    expect(() => writeXmpAttributes(xp, {
      latitude: 20,
    })).toThrow(/written together/)
    expect(() => writeXmpAttributes(xp, {
      dateTaken: '2024-02-30T10:30:00',
    })).toThrow(/dateTaken/)
    expect(() => writeXmpAttributes(xp, {
      keywords: ['valid', 'bad\u0000keyword'],
    })).toThrow(/XML 1.0/)
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

  it('supports standards-only color labels without Capture One urgency', async () => {
    const xp = xmpPath(dir)
    await writeXmpAttributesAsync(xp, {
      label: 'Green',
      writeUrgency: false,
    })

    const content = readFile(xp)
    expect(content).toContain('xmp:Label')
    expect(content).not.toContain('photoshop:Urgency')
    expect(extractXmpAttributes((await parseXmpAsync(xp))!)).toMatchObject({
      label: 'Green',
    })
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
