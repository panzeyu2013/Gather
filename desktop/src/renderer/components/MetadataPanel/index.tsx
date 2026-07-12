import React, { useEffect, useState } from 'react'
import { metadataApi } from '../../api/metadata'
import type { MetadataTags } from '@gather/shared'
import EditableField from './EditableField'
import styles from './MetadataPanel.module.css'

interface MetadataPanelProps {
  photoIds: string[]
}

type MetadataSection = {
  title: string
  fields: { label: string; key: keyof MetadataTags }[]
}

const SECTIONS: MetadataSection[] = [
  {
    title: '文件',
    fields: [
      { label: '文件名', key: 'filename' },
      { label: '文件大小', key: 'fileSize' },
      { label: '格式', key: 'format' },
      { label: '尺寸', key: 'width' },
    ],
  },
  {
    title: '相机',
    fields: [
      { label: '品牌', key: 'make' },
      { label: '型号', key: 'model' },
      { label: '序列号', key: 'serialNumber' },
    ],
  },
  {
    title: '镜头',
    fields: [
      { label: '镜头型号', key: 'lensModel' },
      { label: '最大光圈', key: 'maxAperture' },
    ],
  },
  {
    title: '拍摄',
    fields: [
      { label: '焦距', key: 'focalLength' },
      { label: '光圈', key: 'aperture' },
      { label: '快门速度', key: 'shutterSpeed' },
      { label: 'ISO', key: 'iso' },
      { label: '曝光补偿', key: 'exposureComp' },
      { label: '测光模式', key: 'meteringMode' },
      { label: '白平衡', key: 'whiteBalance' },
    ],
  },
  {
    title: '时间',
    fields: [
      { label: '拍摄日期', key: 'dateTaken' },
      { label: '数字化日期', key: 'dateDigitized' },
    ],
  },
  {
    title: 'GPS',
    fields: [
      { label: '纬度', key: 'latitude' },
      { label: '经度', key: 'longitude' },
      { label: '海拔', key: 'altitude' },
    ],
  },
  {
    title: 'XMP',
    fields: [
      { label: '标题', key: 'title' },
      { label: '描述', key: 'description' },
      { label: '作者', key: 'author' },
      { label: '版权', key: 'copyright' },
      { label: '评级', key: 'rating' },
      { label: '标签', key: 'keywords' },
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
    return <div className={styles.panel}><div className={styles.loading}>加载中...</div></div>
  }

  const primaryTags = photoIds.length > 0 ? metadata.get(photoIds[0]) : undefined

  return (
    <div className={styles.panel}>
      {SECTIONS.map((section) => (
        <div key={section.title} className={styles.section}>
          <div className={styles.sectionTitle}>{section.title}</div>
          {section.fields.map((field) => (
            <EditableField
              key={field.key}
              label={field.label}
              value={formatValue(primaryTags?.[field.key])}
              readOnly
            />
          ))}
        </div>
      ))}
    </div>
  )
}
