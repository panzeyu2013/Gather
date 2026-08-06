import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'
import { SCHEMA_SQL } from '../../../desktop/src/main/db/schema'
import { getXmpSidecarPath } from '../../../desktop/src/main/services/xmp/xmp-sidecar-writer'
import { extractKeywords, parseXmp, writeXmpAttributes } from '../../../desktop/src/main/services/xmp/xmp-utils'
import { createReliabilityFixture } from '../../fixtures/reliability-fixtures'

const fixtureRoots: string[] = []

afterEach(async () => {
  await Promise.all(fixtureRoots.splice(0).map((root) => fs.rm(root, { recursive: true, force: true })))
})

describe('P0-0 reliability fixtures', () => {
  it('matches the current schema table snapshot', async () => {
    // Resolve relative to this test file so the outcome never depends on the
    // working directory the runner was launched from.
    const testDir = path.dirname(fileURLToPath(import.meta.url))
    const snapshotPath = path.resolve(testDir, '../../../docs/fixtures/schema-v27.snapshot.json')
    const snapshot = JSON.parse(await fs.readFile(snapshotPath, 'utf8')) as { schemaVersion: number; tables: string[] }
    const tables = [...SCHEMA_SQL.matchAll(/CREATE TABLE IF NOT EXISTS\s+([a-z_]+)/g)]
      .map((match) => match[1])
      .sort()

    expect(snapshot.schemaVersion).toBe(27)
    expect(tables).toEqual([...snapshot.tables].sort())
  })

  it('creates valid JPEG, shared RAW/JPEG sidecar, and broken-file fixtures', async () => {
    const fixture = await createReliabilityFixture()
    fixtureRoots.push(fixture.root)
    const jpegPath = await fixture.createJpeg()
    const pair = await fixture.createSharedRawJpegPair('IMG_0002')
    const brokenPath = await fixture.createInvalidFile()

    expect((await fs.stat(jpegPath)).size).toBeGreaterThan(0)
    expect(getXmpSidecarPath(pair.rawPath)).toBe(pair.xmpPath)
    expect(getXmpSidecarPath(pair.jpegPath)).toBe(pair.xmpPath)
    expect((await fs.readFile(brokenPath)).toString()).toBe('not-a-valid-image')
  })

  it('preserves unknown XMP fields while writing shared metadata', async () => {
    const fixture = await createReliabilityFixture()
    fixtureRoots.push(fixture.root)
    const pair = await fixture.createSharedRawJpegPair()
    await fs.writeFile(pair.xmpPath, `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:custom="urn:gather:test">
      <custom:KeepMe>external-value</custom:KeepMe>
      <dc:subject><rdf:Bag><rdf:li>existing</rdf:li></rdf:Bag></dc:subject>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>`)

    writeXmpAttributes(pair.xmpPath, { keywords: ['existing', 'person:alice'], rating: 4, label: 'Green' })
    const content = await fs.readFile(pair.xmpPath, 'utf8')
    const parsed = parseXmp(pair.xmpPath)
    expect(content).toContain('KeepMe')
    expect(content).toContain('external-value')
    expect(extractKeywords(parsed!)).toEqual(['existing', 'person:alice'])
  })
})
