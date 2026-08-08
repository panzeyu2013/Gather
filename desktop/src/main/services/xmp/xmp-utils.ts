import { existsSync, readFileSync, writeFileSync, copyFileSync, renameSync, unlinkSync } from 'fs'
import { access, copyFile, open, readFile, readdir, rename, unlink } from 'fs/promises'
import { randomUUID } from 'crypto'
import { XMLParser, XMLBuilder } from 'fast-xml-parser'
import * as path from 'path'

export interface XmpDescription {
  '@_rdf:about'?: string
  '@_xmlns:dc'?: string
  '@_xmlns:xmp'?: string
  '@_xmlns:exif'?: string
  '@_xmlns:photoshop'?: string
  'dc:subject'?: {
    'rdf:Bag': {
      'rdf:li': string[]
    }
  }
  [key: string]: unknown
}

export interface XmpDoc {
  '?xml'?: { '@_version': string; '@_encoding': string }
  'x:xmpmeta': {
    '@_xmlns:x': string
    'rdf:RDF': {
      '@_xmlns:rdf': string
      'rdf:Description': XmpDescription | XmpDescription[]
    }
    [key: string]: unknown
  }
}

export const DC_NS = 'http://purl.org/dc/elements/1.1/'
export const RDF_NS = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
export const XMPMETA_NS = 'adobe:ns:meta/'
const XMP_NS = 'http://ns.adobe.com/xap/1.0/'
const EXIF_NS = 'http://ns.adobe.com/exif/1.0/'
const PHOTOSHOP_NS = 'http://ns.adobe.com/photoshop/1.0/'

const CAPTURE_ONE_LABEL_URGENCY: Readonly<Record<string, number>> = {
  Red: 1,
  Green: 2,
  Blue: 3,
  Pink: 4,
  Purple: 5,
  Orange: 6,
  Yellow: 7,
}

const CAPTURE_ONE_URGENCY_LABEL = new Map(
  Object.entries(CAPTURE_ONE_LABEL_URGENCY).map(([label, urgency]) => [urgency, label]),
)

const INVALID_XML_TEXT = /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/
// Bound the map so long-running sessions touching many distinct directories
// do not grow it without limit; clearing evicts entries wholesale, and a
// dropped entry only means the next write re-runs the (idempotent) cleanup.
const MAX_TEMP_CLEANUP_ENTRIES = 100
const TEMP_DIRECTORY_CLEANUPS = new Map<string, Promise<void>>()

async function cleanupStaleGatherTemps(directoryPath: string): Promise<void> {
  const existing = TEMP_DIRECTORY_CLEANUPS.get(directoryPath)
  if (existing) return existing
  if (TEMP_DIRECTORY_CLEANUPS.size >= MAX_TEMP_CLEANUP_ENTRIES) {
    TEMP_DIRECTORY_CLEANUPS.clear()
  }
  const cleanup = (async () => {
    try {
      const names = await readdir(directoryPath)
      await Promise.all(names
        .filter(name =>
          name.includes('.xmp.tmp-') ||
          name.includes('.xmp.restore-'),
        )
        .map(name => unlink(path.join(directoryPath, name)).catch(() => undefined)))
    } catch {
      // The following write reports a precise error if the directory is unusable.
    }
  })()
  TEMP_DIRECTORY_CLEANUPS.set(directoryPath, cleanup)
  await cleanup
}

export function createEmptyXmpDoc(): XmpDoc {
  return {
    'x:xmpmeta': {
      '@_xmlns:x': XMPMETA_NS,
      'rdf:RDF': {
        '@_xmlns:rdf': RDF_NS,
        'rdf:Description': {
          '@_rdf:about': '',
          '@_xmlns:dc': DC_NS,
        },
      },
    },
  }
}

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  // XMP scalar values are lexical XML text. Automatic coercion would turn
  // legitimate keywords such as "00123" or "true" into numbers/booleans.
  parseTagValue: false,
  isArray: (name) => name === 'rdf:li',
})

const builder = new XMLBuilder({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  format: true,
  suppressBooleanAttributes: false,
})

export function parseXmp(xmlPath: string): XmpDoc | null {
  const xml = readFileSync(xmlPath, 'utf-8')
  return parseXmpText(xml)
}

function parseXmpText(xml: string): XmpDoc | null {
  try {
    return parser.parse(xml) as XmpDoc
  } catch {
    return null
  }
}

export async function parseXmpAsync(xmlPath: string): Promise<XmpDoc | null> {
  const xml = await readFile(xmlPath, 'utf-8')
  return parseXmpText(xml)
}

export function extractKeywords(doc: XmpDoc): string[] {
  try {
    const descriptions = getDescriptionArray(doc)
    for (const desc of descriptions) {
      const li = desc['dc:subject']?.['rdf:Bag']?.['rdf:li']
      if (li) {
        return Array.isArray(li) ? li : [li]
      }
    }
    return []
  } catch {
    return []
  }
}

export function extractXmpAttributes(doc: XmpDoc): {
  keywords: string[]
  rating?: number
  label?: string
  dateTaken?: string
  latitude?: number
  longitude?: number
} {
  const result: {
    keywords: string[]
    rating?: number
    label?: string
    dateTaken?: string
    latitude?: number
    longitude?: number
  } = { keywords: extractKeywords(doc) }
  for (const description of getDescriptionArray(doc)) {
    const rating = getSimpleProperty(description, 'xmp:Rating')
    if (result.rating === undefined && (typeof rating === 'string' || typeof rating === 'number')) {
      const parsed = Number(rating)
      if (Number.isFinite(parsed)) result.rating = parsed
    }
    const label = getSimpleProperty(description, 'xmp:Label')
    if (result.label === undefined && typeof label === 'string' && label.trim()) {
      result.label = label.trim()
    }
    const dateTaken =
      getSimpleProperty(description, 'exif:DateTimeOriginal') ??
      getSimpleProperty(description, 'xmp:CreateDate')
    if (result.dateTaken === undefined && typeof dateTaken === 'string') {
      result.dateTaken = dateTaken
    }
    const latitude = parseGpsCoordinate(
      getSimpleProperty(description, 'exif:GPSLatitude'),
      'latitude',
    )
    if (result.latitude === undefined && latitude !== undefined) {
      result.latitude = latitude
    }
    const longitude = parseGpsCoordinate(
      getSimpleProperty(description, 'exif:GPSLongitude'),
      'longitude',
    )
    if (result.longitude === undefined && longitude !== undefined) {
      result.longitude = longitude
    }
  }
  if (result.label === undefined) {
    for (const description of getDescriptionArray(doc)) {
      const urgency = Number(getSimpleProperty(description, 'photoshop:Urgency'))
      const label = CAPTURE_ONE_URGENCY_LABEL.get(urgency)
      if (label) {
        result.label = label
        break
      }
    }
  }
  return result
}

export function writeXmpAttributes(
  xmpPath: string,
  tags: { keywords?: string[]; rating?: number; label?: string; dateTaken?: string; latitude?: number; longitude?: number; writeUrgency?: boolean },
): void {
  try {
    let doc: XmpDoc
    if (existsSync(xmpPath)) {
      const parsed = parseXmp(xmpPath)
      if (!parsed) throw new Error(`Corrupt XMP file: ${xmpPath}`)
      doc = parsed
    } else {
      doc = createEmptyXmpDoc()
    }

    const xml = buildXmpAttributesXml(doc, tags)
    const tmpPath = xmpPath + '.tmp'
    writeFileSync(tmpPath, xml, 'utf-8')
    try {
      renameSync(tmpPath, xmpPath)
    } catch (renameErr) {
      try { unlinkSync(tmpPath) } catch { /* best effort */ }
      throw renameErr
    }
  } catch (e) {
    throw new Error(`Failed to write XMP attributes to ${xmpPath}: ${e instanceof Error ? e.message : String(e)}`)
  }
}

type XmpAttributeInput = {
  keywords?: string[]
  rating?: number
  label?: string
  dateTaken?: string
  latitude?: number
  longitude?: number
  writeUrgency?: boolean
}

function buildXmpAttributesXml(doc: XmpDoc, tags: XmpAttributeInput): string {
  tags = normalizeXmpAttributeInput(tags)
  delete doc['?xml']
  const descriptions = getDescriptionArray(doc)

  if (tags.keywords !== undefined) {
    const desc = resolveTargetDescription(doc, descriptions, 'dc:subject', '@_xmlns:dc', DC_NS)
    for (const d of descriptions) {
      if (d !== desc) delete d['dc:subject']
    }
    if (tags.keywords.length > 0) {
      desc['dc:subject'] = { 'rdf:Bag': { 'rdf:li': tags.keywords } }
    } else {
      delete desc['dc:subject']
    }
  }
  if (tags.rating !== undefined) {
    setSimpleProperty(
      doc,
      descriptions,
      'xmp:Rating',
      '@_xmlns:xmp',
      XMP_NS,
      String(tags.rating),
    )
  }
  if (tags.label !== undefined) {
    removeSimpleProperty(descriptions, 'xmp:Label')
    removeSimpleProperty(descriptions, 'photoshop:Urgency')
    if (tags.label) {
      setSimpleProperty(
        doc,
        descriptions,
        'xmp:Label',
        '@_xmlns:xmp',
        XMP_NS,
        tags.label,
      )
      const urgency = CAPTURE_ONE_LABEL_URGENCY[tags.label]
      if (tags.writeUrgency !== false && urgency !== undefined) {
        setSimpleProperty(
          doc,
          descriptions,
          'photoshop:Urgency',
          '@_xmlns:photoshop',
          PHOTOSHOP_NS,
          String(urgency),
        )
      }
    }
  }
  if (tags.dateTaken !== undefined) {
    setSimpleProperty(
      doc,
      descriptions,
      'exif:DateTimeOriginal',
      '@_xmlns:exif',
      EXIF_NS,
      tags.dateTaken,
    )
  }
  if (tags.latitude !== undefined && tags.longitude !== undefined) {
    setSimpleProperty(
      doc,
      descriptions,
      'exif:GPSLatitude',
      '@_xmlns:exif',
      EXIF_NS,
      formatGpsCoordinate(tags.latitude, 'latitude'),
    )
    setSimpleProperty(
      doc,
      descriptions,
      'exif:GPSLongitude',
      '@_xmlns:exif',
      EXIF_NS,
      formatGpsCoordinate(tags.longitude, 'longitude'),
    )
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n' + builder.build(doc)
}

export async function writeXmpAttributesAsync(
  xmpPath: string,
  tags: XmpAttributeInput,
): Promise<void> {
  try {
    await cleanupStaleGatherTemps(path.dirname(xmpPath))
    let doc: XmpDoc
    try {
      const parsed = await parseXmpAsync(xmpPath)
      if (!parsed) throw new Error(`Corrupt XMP file: ${xmpPath}`)
      doc = parsed
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      doc = createEmptyXmpDoc()
    }
    const xml = buildXmpAttributesXml(doc, tags)
    const tmpPath = `${xmpPath}.tmp-${process.pid}-${randomUUID()}`
    try {
      const handle = await open(tmpPath, 'wx')
      try {
        await handle.writeFile(xml, 'utf-8')
        await handle.sync()
      } finally {
        await handle.close()
      }
      await rename(tmpPath, xmpPath)
      // Persist the directory entry where supported. Some filesystems reject
      // opening directories; the file itself has already been fsynced.
      try {
        const directory = await open(path.dirname(xmpPath), 'r')
        try {
          await directory.sync()
        } finally {
          await directory.close()
        }
      } catch {
        // Best effort across filesystems and platforms.
      }
    } catch (writeError) {
      await unlink(tmpPath).catch(() => undefined)
      throw writeError
    }
  } catch (error) {
    throw new Error(`Failed to write XMP attributes to ${xmpPath}: ${error instanceof Error ? error.message : String(error)}`)
  }
}

export function backupXmpFile(xmpPath: string): string {
  const backupPath = `${xmpPath}.gather-backup-${randomUUID()}`
  if (existsSync(xmpPath)) {
    copyFileSync(xmpPath, backupPath)
  }
  return backupPath
}

export function restoreXmpFile(xmpPath: string, backupPath: string): void {
  if (existsSync(backupPath)) {
    copyFileSync(backupPath, xmpPath)
    unlinkSync(backupPath)
  }
}

export async function backupXmpFileAsync(xmpPath: string): Promise<string> {
  const backupPath = `${xmpPath}.gather-backup-${randomUUID()}`
  try {
    await access(xmpPath)
    await copyFile(xmpPath, backupPath)
    const handle = await open(backupPath, 'r')
    try {
      await handle.sync()
    } finally {
      await handle.close()
    }
    await syncDirectory(path.dirname(backupPath))
    return backupPath
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw error
  }
}

export async function restoreXmpFileAsync(xmpPath: string, backupPath: string): Promise<void> {
  try {
    await access(backupPath)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
    throw error
  }
  await cleanupStaleGatherTemps(path.dirname(xmpPath))
  const tempPath = `${xmpPath}.restore-${process.pid}-${randomUUID()}`
  try {
    await copyFile(backupPath, tempPath)
    const handle = await open(tempPath, 'r')
    try {
      await handle.sync()
    } finally {
      await handle.close()
    }
    await rename(tempPath, xmpPath)
    await syncDirectory(path.dirname(xmpPath))
    await unlink(backupPath)
  } catch (error) {
    await unlink(tempPath).catch(() => undefined)
    throw error
  }
}

async function syncDirectory(directoryPath: string): Promise<void> {
  try {
    const directory = await open(directoryPath, 'r')
    try {
      await directory.sync()
    } finally {
      await directory.close()
    }
  } catch {
    // Directory handles are not available on every supported filesystem.
  }
}

function getDescriptionArray(doc: XmpDoc): XmpDescription[] {
  const rdf = doc['x:xmpmeta']?.['rdf:RDF']
  if (!rdf) return []
  const desc = rdf['rdf:Description']
  if (!desc) {
    const descriptions: XmpDescription[] = []
    rdf['rdf:Description'] = descriptions
    return descriptions
  }
  if (!Array.isArray(desc)) {
    rdf['rdf:Description'] = [desc]
  }
  return rdf['rdf:Description'] as XmpDescription[]
}

function resolveTargetDescription(doc: XmpDoc, descs: XmpDescription[], targetKey: string, nsAttr: string, nsUri: string): XmpDescription {
  let desc = descs.find(d => targetKey in d || `@_${targetKey}` in d)
  if (desc) {
    if (!desc[nsAttr]) desc[nsAttr] = nsUri
    return desc
  }

  desc = descs.find(d => d[nsAttr] === nsUri)
  if (desc) return desc

  const rootNs = (doc['x:xmpmeta'] as Record<string, unknown>)[nsAttr]
  if (rootNs === nsUri && descs.length > 0) {
    return descs[0]
  }

  desc = { '@_rdf:about': '', [nsAttr]: nsUri }
  descs.push(desc)
  return desc
}

function getSimpleProperty(description: XmpDescription, property: string): unknown {
  return description[property] ?? description[`@_${property}`]
}

function removeSimpleProperty(descriptions: XmpDescription[], property: string): void {
  for (const description of descriptions) {
    delete description[property]
    delete description[`@_${property}`]
  }
}

function setSimpleProperty(
  doc: XmpDoc,
  descriptions: XmpDescription[],
  property: string,
  namespaceAttribute: string,
  namespaceUri: string,
  value: string,
): void {
  const target = resolveTargetDescription(
    doc,
    descriptions,
    property,
    namespaceAttribute,
    namespaceUri,
  )
  removeSimpleProperty(descriptions, property)
  if (!target[namespaceAttribute]) target[namespaceAttribute] = namespaceUri
  target[property] = value
}

function normalizeXmpAttributeInput(tags: XmpAttributeInput): XmpAttributeInput {
  const normalized: XmpAttributeInput = {}
  normalized.writeUrgency = tags.writeUrgency !== false

  if (tags.keywords !== undefined) {
    if (!Array.isArray(tags.keywords) || !tags.keywords.every(keyword => typeof keyword === 'string')) {
      throw new Error('keywords must be an array of strings')
    }
    normalized.keywords = [...new Set(
      tags.keywords
        .map(keyword => keyword.trim())
        .filter(Boolean),
    )]
    for (const keyword of normalized.keywords) {
      assertValidXmlText(keyword, 'keyword')
    }
  }

  if (tags.rating !== undefined) {
    if (
      typeof tags.rating !== 'number' ||
      !Number.isInteger(tags.rating) ||
      (tags.rating !== -1 && (tags.rating < 0 || tags.rating > 5))
    ) {
      throw new Error('rating must be -1 or an integer from 0 to 5')
    }
    normalized.rating = tags.rating
  }

  if (tags.label !== undefined) {
    if (typeof tags.label !== 'string') throw new Error('label must be a string')
    normalized.label = tags.label.trim()
    assertValidXmlText(normalized.label, 'label')
  }

  if (tags.dateTaken !== undefined) {
    if (typeof tags.dateTaken !== 'string' || !isValidXmpDate(tags.dateTaken.trim())) {
      throw new Error('dateTaken must be a valid ISO 8601/XMP date')
    }
    normalized.dateTaken = tags.dateTaken.trim()
  }

  const hasLatitude = tags.latitude !== undefined
  const hasLongitude = tags.longitude !== undefined
  if (hasLatitude !== hasLongitude) {
    throw new Error('latitude and longitude must be written together')
  }
  if (hasLatitude && hasLongitude) {
    if (
      typeof tags.latitude !== 'number' ||
      !Number.isFinite(tags.latitude) ||
      tags.latitude < -90 ||
      tags.latitude > 90
    ) {
      throw new Error('latitude must be a finite number from -90 to 90')
    }
    if (
      typeof tags.longitude !== 'number' ||
      !Number.isFinite(tags.longitude) ||
      tags.longitude < -180 ||
      tags.longitude > 180
    ) {
      throw new Error('longitude must be a finite number from -180 to 180')
    }
    normalized.latitude = tags.latitude
    normalized.longitude = tags.longitude
  }

  return normalized
}

function assertValidXmlText(value: string, field: string): void {
  if (INVALID_XML_TEXT.test(value)) {
    throw new Error(`${field} contains characters that are not valid in XML 1.0`)
  }
}

function isValidXmpDate(value: string): boolean {
  const match = value.match(
    /^(\d{4})(?:-(\d{2})(?:-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:\d{2})?)?)?)?$/,
  )
  if (!match) return false
  const year = Number(match[1])
  const month = match[2] === undefined ? undefined : Number(match[2])
  const day = match[3] === undefined ? undefined : Number(match[3])
  const hour = match[4] === undefined ? undefined : Number(match[4])
  const minute = match[5] === undefined ? undefined : Number(match[5])
  const second = match[6] === undefined ? undefined : Number(match[6])

  if (year < 1) return false
  if (month !== undefined && (month < 1 || month > 12)) return false
  if (day !== undefined) {
    if (month === undefined) return false
    const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate()
    if (day < 1 || day > daysInMonth) return false
  }
  if (hour !== undefined && (hour < 0 || hour > 23)) return false
  if (minute !== undefined && (minute < 0 || minute > 59)) return false
  if (second !== undefined && (second < 0 || second > 59)) return false

  const timezone = match[8]
  if (timezone && timezone !== 'Z') {
    const [timezoneHour, timezoneMinute] = timezone.slice(1).split(':').map(Number)
    if (timezoneHour > 23 || timezoneMinute > 59) return false
  }
  return true
}

function formatGpsCoordinate(
  value: number,
  axis: 'latitude' | 'longitude',
): string {
  const absolute = Math.abs(value)
  let degrees = Math.floor(absolute)
  let minutes = Number(((absolute - degrees) * 60).toFixed(8))
  if (minutes >= 60) {
    degrees++
    minutes = 0
  }
  const direction = axis === 'latitude'
    ? value < 0 ? 'S' : 'N'
    : value < 0 ? 'W' : 'E'
  return `${degrees},${minutes}${direction}`
}

function parseGpsCoordinate(
  value: unknown,
  axis: 'latitude' | 'longitude',
): number | undefined {
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined
  if (typeof value !== 'string') return undefined
  const text = value.trim()
  const direction = text.match(/[NSEW]$/i)?.[0].toUpperCase()
  const numericText = direction ? text.slice(0, -1).trim() : text
  const parts = numericText
    .split(/[,\s°'"]+/)
    .filter(Boolean)
    .map(Number)
  if (parts.length < 1 || parts.length > 3 || parts.some(part => !Number.isFinite(part))) {
    return undefined
  }
  const signFromNumber = parts[0] < 0 ? -1 : 1
  const absolute =
    Math.abs(parts[0]) +
    (parts[1] ?? 0) / 60 +
    (parts[2] ?? 0) / 3600
  const signFromDirection =
    direction === 'S' || direction === 'W' ? -1 :
      direction === 'N' || direction === 'E' ? 1 :
        signFromNumber
  const coordinate = absolute * signFromDirection
  const limit = axis === 'latitude' ? 90 : 180
  return coordinate >= -limit && coordinate <= limit ? coordinate : undefined
}
