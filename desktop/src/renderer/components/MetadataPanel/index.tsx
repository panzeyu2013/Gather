import React, { useEffect, useState } from 'react'
import { metadataApi } from '../../api/metadata'
import type { MetadataTags } from '@gather/shared'
import { useTranslation, type TranslationKey } from '../../locales'
import EditableField from './EditableField'
import styles from './MetadataPanel.module.css'

interface MetadataPanelProps {
  photoIds: string[]
}

type MetadataSection = {
  titleKey: TranslationKey
  fields: { labelKey: TranslationKey; key: keyof MetadataTags }[]
}

const SECTIONS: MetadataSection[] = [
  {
    titleKey: 'metadata.file',
    fields: [
      { labelKey: 'metadata.filename', key: 'filename' },
      { labelKey: 'metadata.fileSize', key: 'fileSize' },
      { labelKey: 'metadata.format', key: 'format' },
      { labelKey: 'metadata.dimensions', key: 'width' },
    ],
  },
  {
    titleKey: 'metadata.camera',
    fields: [
      { labelKey: 'metadata.make', key: 'make' },
      { labelKey: 'metadata.model', key: 'model' },
      { labelKey: 'metadata.serialNumber', key: 'serialNumber' },
    ],
  },
  {
    titleKey: 'metadata.lens',
    fields: [
      { labelKey: 'metadata.lensModel', key: 'lensModel' },
      { labelKey: 'metadata.maxAperture', key: 'maxAperture' },
    ],
  },
  {
    titleKey: 'metadata.shooting',
    fields: [
      { labelKey: 'metadata.focalLength', key: 'focalLength' },
      { labelKey: 'metadata.aperture', key: 'aperture' },
      { labelKey: 'metadata.shutterSpeed', key: 'shutterSpeed' },
      { labelKey: 'metadata.iso', key: 'iso' },
      { labelKey: 'metadata.exposureComp', key: 'exposureComp' },
      { labelKey: 'metadata.meteringMode', key: 'meteringMode' },
      { labelKey: 'metadata.whiteBalance', key: 'whiteBalance' },
    ],
  },
  {
    titleKey: 'metadata.time',
    fields: [
      { labelKey: 'metadata.dateTaken', key: 'dateTaken' },
      { labelKey: 'metadata.dateDigitized', key: 'dateDigitized' },
    ],
  },
  {
    titleKey: 'metadata.gps',
    fields: [
      { labelKey: 'metadata.latitude', key: 'latitude' },
      { labelKey: 'metadata.longitude', key: 'longitude' },
      { labelKey: 'metadata.altitude', key: 'altitude' },
    ],
  },
  {
    titleKey: 'metadata.xmp',
    fields: [
      { labelKey: 'metadata.title', key: 'title' },
      { labelKey: 'metadata.description', key: 'description' },
      { labelKey: 'metadata.author', key: 'author' },
      { labelKey: 'metadata.copyright', key: 'copyright' },
      { labelKey: 'metadata.rating', key: 'rating' },
      { labelKey: 'metadata.keywords', key: 'keywords' },
    ],
  },
]

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return '—'
  if (Array.isArray(value)) return value.join(', ')
  if (typeof value === 'number') return String(value)
  return String(value)
}

export default function MetadataPanel({ photoIds }: MetadataPanelProps) {
  const { t } = useTranslation()
  const [metadata, setMetadata] = useState<Map<string, MetadataTags>>(new Map())
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    const ids = photoIds
    metadataApi
      .get(ids)
      .then((data) => {
        if (cancelled) return
        const map = new Map<string, MetadataTags>()
        for (const [id, tags] of Object.entries(data)) {
          map.set(id, tags as MetadataTags)
        }
        setMetadata(map)
      })
      .catch(() => {
        if (!cancelled) setMetadata(new Map())
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [photoIds.join(',')])

  if (loading) {
    return <div className={styles.panel}><div className={styles.loading}>{t('metadata.loading')}</div></div>
  }

  const primaryTags = photoIds.length > 0 ? metadata.get(photoIds[0]) : undefined

  return (
    <div className={styles.panel}>
      {SECTIONS.map((section) => (
        <div key={section.titleKey} className={styles.section}>
          <div className={styles.sectionTitle}>{t(section.titleKey)}</div>
          {section.fields.map((field) => (
            <EditableField
              key={field.key}
              label={t(field.labelKey)}
              value={formatValue(primaryTags?.[field.key])}
              readOnly
            />
          ))}
        </div>
      ))}
    </div>
  )
}
