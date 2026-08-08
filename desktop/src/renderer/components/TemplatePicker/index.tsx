import React, { useEffect, useState } from 'react'
import type { TemplateData } from '@gather/shared'
import { templateApi } from '../../api/template'
import { useTranslation } from '../../locales'
import styles from './TemplatePicker.module.css'

interface TemplatePickerProps {
  onSelect: (template: TemplateData | null) => void
}

export default function TemplatePicker({ onSelect }: TemplatePickerProps) {
  const { t } = useTranslation()
  const [templates, setTemplates] = useState<TemplateData[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    templateApi
      .list()
      .then((data) => { if (!cancelled) setTemplates(data) })
      .catch(() => { if (!cancelled) setTemplates([]) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])

  const handleSelect = (template: TemplateData | null) => {
    setSelectedId(template ? template.id : null)
    onSelect(template)
  }

  if (loading) {
    return <div className={styles.container}>{t('template.loading')}</div>
  }

  return (
    <div className={styles.container}>
      <h3 className={styles.heading}>{t('template.heading')}</h3>
      <div className={styles.grid}>
        <button
          className={`${styles.card} ${selectedId === null ? styles.cardSelected : ''}`}
          onClick={() => handleSelect(null)}
        >
          <div className={styles.cardIcon}>✨</div>
          <div className={styles.cardTitle}>{t('template.none')}</div>
          <div className={styles.cardDesc}>{t('template.noneHint')}</div>
        </button>
        {templates.map((template) => (
          <button
            key={template.id}
            className={`${styles.card} ${selectedId === template.id ? styles.cardSelected : ''}`}
            onClick={() => handleSelect(template)}
          >
            <div className={styles.cardIcon}>📋</div>
            <div className={styles.cardTitle}>{template.name}</div>
            <div className={styles.cardDesc}>{template.description || t('template.noDescription')}</div>
          </button>
        ))}
      </div>
    </div>
  )
}
