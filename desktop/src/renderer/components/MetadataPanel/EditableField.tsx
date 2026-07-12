import React from 'react'
import styles from './MetadataPanel.module.css'

interface EditableFieldProps {
  label: string
  value: string
  readOnly?: boolean
  onChange?: (v: string) => void
}

export default function EditableField({ label, value, readOnly, onChange }: EditableFieldProps) {
  return (
    <div className={styles.field}>
      <span className={styles.fieldLabel}>{label}</span>
      {readOnly ? (
        <span className={styles.fieldValue}>{value}</span>
      ) : (
        <input
          className={styles.fieldInput}
          value={value}
          onChange={(e) => onChange?.(e.target.value)}
        />
      )}
    </div>
  )
}
