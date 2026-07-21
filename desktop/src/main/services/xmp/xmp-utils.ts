import { existsSync, readFileSync, writeFileSync, copyFileSync, renameSync, unlinkSync } from 'fs'
import { XMLParser, XMLBuilder } from 'fast-xml-parser'

export interface XmpDoc {
  'x:xmpmeta': {
    '@_xmlns:x': string
    'rdf:RDF': {
      '@_xmlns:rdf': string
      'rdf:Description': {
        '@_rdf:about': string
        '@_xmlns:dc': string
        'dc:subject'?: {
          'rdf:Bag': {
            'rdf:li': string[]
          }
        }
      }
    }
  }
}

export const DC_NS = 'http://purl.org/dc/elements/1.1/'
export const RDF_NS = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
export const XMPMETA_NS = 'adobe:ns:meta/'

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
    const li = doc['x:xmpmeta']['rdf:RDF']['rdf:Description']['dc:subject']?.['rdf:Bag']?.['rdf:li']
    if (!li) return []
    return Array.isArray(li) ? li : [li]
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
    const rdf = doc['x:xmpmeta']?.['rdf:RDF'] as Record<string, unknown> | undefined
    if (!rdf) throw new Error('Invalid XMP structure')
    const desc = rdf['rdf:Description'] as Record<string, unknown>

    if (tags.keywords !== undefined) {
      const keywords = tags.keywords
      if (keywords.length > 0) {
        desc['dc:subject'] = { 'rdf:Bag': { 'rdf:li': keywords } }
      } else {
        delete desc['dc:subject']
      }
    }
    if (tags.rating !== undefined) {
      desc['@_xmlns:xmp'] = desc['@_xmlns:xmp'] || 'http://ns.adobe.com/xap/1.0/'
      desc['xmp:Rating'] = String(tags.rating)
    }
    if (tags.dateTaken !== undefined) {
      desc['@_xmlns:xmp'] = desc['@_xmlns:xmp'] || 'http://ns.adobe.com/xap/1.0/'
      desc['xmp:CreateDate'] = String(tags.dateTaken)
    }
    if (tags.latitude !== undefined && tags.longitude !== undefined) {
      desc['@_xmlns:exif'] = 'http://ns.adobe.com/exif/1.0/'
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
