import { existsSync, readFileSync, writeFileSync, copyFileSync, renameSync, unlinkSync } from 'fs'
import { XMLParser, XMLBuilder } from 'fast-xml-parser'

export interface XmpDescription {
  '@_rdf:about'?: string
  '@_xmlns:dc'?: string
  '@_xmlns:xmp'?: string
  '@_xmlns:exif'?: string
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
  try {
    return parser.parse(xml) as XmpDoc
  } catch {
    return null
  }
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

export function writeXmpAttributes(
  xmpPath: string,
  tags: { keywords?: string[]; rating?: number; dateTaken?: string; latitude?: number; longitude?: number },
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

    delete doc['?xml']

    const descriptions = getDescriptionArray(doc)

    if (tags.keywords !== undefined) {
      const desc = resolveTargetDescription(doc, descriptions, 'dc:subject', '@_xmlns:dc', DC_NS)
      for (const d of descriptions) {
        if (d !== desc) delete d['dc:subject']
      }
      const keywords = tags.keywords
      if (keywords.length > 0) {
        desc['dc:subject'] = { 'rdf:Bag': { 'rdf:li': keywords } }
      } else {
        delete desc['dc:subject']
      }
    }

    if (tags.rating !== undefined) {
      const desc = resolveTargetDescription(doc, descriptions, 'xmp:Rating', '@_xmlns:xmp', XMP_NS)
      desc['xmp:Rating'] = String(tags.rating)
    }

    if (tags.dateTaken !== undefined) {
      const desc = resolveTargetDescription(doc, descriptions, 'xmp:CreateDate', '@_xmlns:xmp', XMP_NS)
      desc['xmp:CreateDate'] = String(tags.dateTaken)
    }

    if (tags.latitude !== undefined && tags.longitude !== undefined) {
      const desc = resolveTargetDescription(doc, descriptions, 'exif:GPSLatitude', '@_xmlns:exif', EXIF_NS)
      desc['exif:GPSLatitude'] = String(tags.latitude)
      desc['exif:GPSLongitude'] = String(tags.longitude)
    }

    const xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + builder.build(doc)
    const tmpPath = xmpPath + '.tmp'
    writeFileSync(tmpPath, xml, 'utf-8')
    renameSync(tmpPath, xmpPath)
  } catch (e) {
    throw new Error(`Failed to write XMP attributes to ${xmpPath}: ${e instanceof Error ? e.message : String(e)}`)
  }
}

export function backupXmpFile(xmpPath: string): string {
  const backupPath = xmpPath + '.bak'
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

function getDescriptionArray(doc: XmpDoc): XmpDescription[] {
  const rdf = doc['x:xmpmeta']?.['rdf:RDF']
  if (!rdf) return []
  const desc = rdf['rdf:Description']
  if (!desc) {
    rdf['rdf:Description'] = []
    return []
  }
  if (!Array.isArray(desc)) {
    rdf['rdf:Description'] = [desc]
  }
  return rdf['rdf:Description'] as XmpDescription[]
}

function resolveTargetDescription(doc: XmpDoc, descs: XmpDescription[], targetKey: string, nsAttr: string, nsUri: string): XmpDescription {
  let desc = descs.find(d => targetKey in d)
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
