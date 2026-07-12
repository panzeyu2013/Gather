import React, { useEffect, useState } from 'react'
import type { TemplateData } from '@gather/shared'
import { templateApi } from '../../api/template'
import styles from './TemplatePicker.module.css'

interface TemplatePickerProps {
  onSelect: (template: TemplateData | null) => void
}

export default function TemplatePicker({ onSelect }: TemplatePickerProps) {
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
    return <div className={styles.container}>Loading templates...</div>
  }

  return (
    <div className={styles.container}>
      <h3 className={styles.heading}>Workflow Template</h3>
      <div className={styles.grid}>
        <button
          className={`${styles.card} ${selectedId === null ? styles.cardSelected : ''}`}
          onClick={() => handleSelect(null)}
        >
          <div className={styles.cardIcon}>✨</div>
          <div className={styles.cardTitle}>No Template</div>
          <div className={styles.cardDesc}>Start with default settings</div>
        </button>
        {templates.map((t) => (
          <button
            key={t.id}
            className={`${styles.card} ${selectedId === t.id ? styles.cardSelected : ''}`}
            onClick={() => handleSelect(t)}
          >
            <div className={styles.cardIcon}>📋</div>
            <div className={styles.cardTitle}>{t.name}</div>
            <div className={styles.cardDesc}>{t.description || 'No description'}</div>
          </button>
        ))}
      </div>
    </div>
  )
}
