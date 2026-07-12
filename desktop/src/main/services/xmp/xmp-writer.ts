import { existsSync, readFileSync, writeFileSync, copyFileSync } from 'fs'
import { XMLParser, XMLBuilder } from 'fast-xml-parser'

interface XmpDoc {
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

const DC_NS = 'http://purl.org/dc/elements/1.1/'
const RDF_NS = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
const XMPMETA_NS = 'adobe:ns:meta/'

function createEmptyXmpDoc(): XmpDoc {
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

function parseXmp(xmlPath: string): XmpDoc | null {
  const xml = readFileSync(xmlPath, 'utf-8')
  try {
    return parser.parse(xml) as XmpDoc
  } catch {
    return null
  }
}

function extractKeywords(doc: XmpDoc): string[] {
  try {
    const li = doc['x:xmpmeta']['rdf:RDF']['rdf:Description']['dc:subject']?.['rdf:Bag']?.['rdf:li']
    if (!li) return []
    return Array.isArray(li) ? li : [li]
  } catch {
    return []
  }
}

export class XmpWriter {
  readKeywords(xmpPath: string): string[] {
    if (!existsSync(xmpPath)) return []
    const doc = parseXmp(xmpPath)
    if (!doc) return []
    return extractKeywords(doc)
  }

  writeKeywords(xmpPath: string, keywords: string[]): void {
    const doc = existsSync(xmpPath) ? (parseXmp(xmpPath) ?? createEmptyXmpDoc()) : createEmptyXmpDoc()

    if (keywords.length > 0) {
      doc['x:xmpmeta']['rdf:RDF']['rdf:Description']['dc:subject'] = {
        'rdf:Bag': { 'rdf:li': keywords },
      }
    } else {
      delete doc['x:xmpmeta']['rdf:RDF']['rdf:Description']['dc:subject']
    }

    const xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + builder.build(doc)
    writeFileSync(xmpPath, xml, 'utf-8')
  }

  writeAttributes(xmpPath: string, tags: Record<string, unknown>): void {
    try {
      const doc = existsSync(xmpPath) ? (parseXmp(xmpPath) ?? createEmptyXmpDoc()) : createEmptyXmpDoc()
      const rdf = doc['x:xmpmeta']?.['rdf:RDF'] as Record<string, unknown> | undefined
      if (!rdf) throw new Error('Invalid XMP structure')
      const desc = rdf['rdf:Description'] as Record<string, unknown>

      if (tags.keywords !== undefined) {
        const keywords = tags.keywords as string[]
        if (keywords.length > 0) {
          desc['dc:subject'] = { 'rdf:Bag': { 'rdf:li': keywords } }
        } else {
          delete desc['dc:subject']
        }
      }
      if (tags.rating !== undefined) {
        desc['@_xmlns:xmp'] = 'http://ns.adobe.com/xap/1.0/'
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
      writeFileSync(xmpPath, xml, 'utf-8')
    } catch (e) {
      console.warn('Failed to write XMP attributes to', xmpPath, e)
    }
  }

  backupXmp(xmpPath: string): string {
    const backupPath = xmpPath + '.bak'
    if (existsSync(xmpPath)) {
      copyFileSync(xmpPath, backupPath)
    }
    return backupPath
  }

  restoreXmp(xmpPath: string, backupPath: string): void {
    if (existsSync(backupPath)) {
      copyFileSync(backupPath, xmpPath)
    }
  }
}
