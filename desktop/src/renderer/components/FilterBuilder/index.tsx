import React, { useState, useCallback, useEffect } from 'react'
import type { FilterGroup, FilterRule } from '@gather/shared'
import { filterApi } from '../../api/filter'
import { useTranslation } from '../../locales'
import { FILTER_FIELDS, getFilterOperators, parseFilterValue } from '../FilterBar/filter-constants'
import styles from './FilterBuilder.module.css'

interface FilterBuilderProps {
  sessionId: string
  initialCriteria?: FilterGroup
  onChange: (criteria: FilterGroup) => void
}

export default function FilterBuilder({ sessionId, initialCriteria, onChange }: FilterBuilderProps) {
  const { t } = useTranslation()
  const [criteria, setCriteria] = useState<FilterGroup>(
    initialCriteria ?? { logic: 'and', conditions: [] },
  )
  const [previewCount, setPreviewCount] = useState<number | null>(null)
  const [previewBusy, setPreviewBusy] = useState(false)

  useEffect(() => {
    onChange(criteria)
  }, [])

  useEffect(() => {
    if (initialCriteria) {
      setCriteria(initialCriteria)
    }
  }, [initialCriteria])

  const notify = useCallback(
    (next: FilterGroup) => {
      setCriteria(next)
      onChange(next)
    },
    [onChange],
  )

  const addCondition = useCallback(() => {
    const next: FilterGroup = {
      ...criteria,
      conditions: [
        ...criteria.conditions,
        { field: 'filename', operator: 'contains' as const, value: '' },
      ],
    }
    notify(next)
  }, [criteria, notify])

  const addGroup = useCallback(() => {
    const next: FilterGroup = {
      ...criteria,
      conditions: [
        ...criteria.conditions,
        { logic: 'and' as const, conditions: [] },
      ],
    }
    notify(next)
  }, [criteria, notify])

  const updateCondition = useCallback(
    (index: number, updates: Partial<FilterRule>) => {
      const next = { ...criteria, conditions: [...criteria.conditions] }
      const cond = next.conditions[index]
      if ('field' in cond) {
        next.conditions[index] = { ...cond, ...updates } as FilterRule
      }
      notify(next)
    },
    [criteria, notify],
  )

  const removeCondition = useCallback(
    (index: number) => {
      const next: FilterGroup = {
        ...criteria,
        conditions: criteria.conditions.filter((_, i) => i !== index),
      }
      notify(next)
    },
    [criteria, notify],
  )

  const toggleLogic = useCallback(() => {
    const next: FilterGroup = {
      ...criteria,
      logic: criteria.logic === 'and' ? 'or' : 'and',
    }
    notify(next)
  }, [criteria, notify])

  const updateGroup = useCallback(
    (index: number, child: FilterGroup) => {
      const next = { ...criteria, conditions: [...criteria.conditions] }
      next.conditions[index] = child
      notify(next)
    },
    [criteria, notify],
  )

  const handlePreview = useCallback(async () => {
    setPreviewBusy(true)
    try {
      const photos = await filterApi.photos(sessionId, criteria)
      setPreviewCount(photos.length)
    } catch {
      setPreviewCount(null)
    } finally {
      setPreviewBusy(false)
    }
  }, [criteria])

  return (
    <div className={styles.container}>
      <div className={styles.header}>
        <button
          type="button"
          className={styles.logicBadge}
          onClick={toggleLogic}
          aria-pressed={criteria.logic === 'or'}
        >
          {criteria.logic.toUpperCase()}
        </button>
        <span className={styles.conditionsLabel}>
          {t('filter.conditionCount', { count: criteria.conditions.length })}
        </span>
      </div>

      <div className={styles.conditions}>
        {criteria.conditions.map((condition, index) => (
          <ConditionRow
            key={index}
            sessionId={sessionId}
            condition={condition}
            onChange={(updates) => {
              if ('field' in condition) {
                updateCondition(index, updates as Partial<FilterRule>)
              }
            }}
            onGroupChange={(child) => updateGroup(index, child)}
            onRemove={() => removeCondition(index)}
          />
        ))}
      </div>

      <div className={styles.footer}>
        <div className={styles.addBtns}>
          <button className={styles.btn} onClick={addCondition}>
            {t('filter.addCondition')}
          </button>
          <button className={styles.btnOutline} onClick={addGroup}>
            {t('filter.addGroup')}
          </button>
        </div>
        <div className={styles.previewRow}>
          <button
            className={styles.previewBtn}
            onClick={handlePreview}
            disabled={previewBusy || criteria.conditions.length === 0}
          >
            {previewBusy ? t('filter.counting') : t('filter.previewCount')}
          </button>
          {previewCount !== null && (
            <span className={styles.previewCount}>{t('filter.matching', { count: previewCount })}</span>
          )}
        </div>
      </div>
    </div>
  )
}

function ConditionRow({
  sessionId,
  condition,
  onChange,
  onGroupChange,
  onRemove,
}: {
  sessionId: string
  condition: FilterRule | FilterGroup
  onChange: (updates: Partial<FilterRule>) => void
  onGroupChange: (child: FilterGroup) => void
  onRemove: () => void
}) {
  const { t } = useTranslation()
  if (!('field' in condition)) {
    return (
      <div className={styles.groupWrapper}>
        <FilterBuilder sessionId={sessionId} initialCriteria={condition} onChange={onGroupChange} />
        <button className={styles.removeBtn} onClick={onRemove} aria-label={t('dialog.removeGroup')}>
          &times;
        </button>
      </div>
    )
  }

  const rule = condition as FilterRule
  const operators = getFilterOperators(rule.field)

  return (
    <div className={styles.ruleRow}>
      <select
        className={styles.select}
        value={rule.field}
        onChange={(e) => onChange({ field: e.target.value, operator: getFilterOperators(e.target.value)[0].value })}
      >
        {FILTER_FIELDS.map((f) => (
          <option key={f.value} value={f.value}>
            {t(f.labelKey)}
          </option>
        ))}
      </select>
      <select
        className={styles.selectSm}
        value={rule.operator}
        onChange={(e) => onChange({ operator: e.target.value as FilterRule['operator'] })}
      >
        {operators.map((op) => (
          <option key={op.value} value={op.value}>
            {t(op.labelKey)}
          </option>
        ))}
      </select>
      {rule.operator !== 'exists' && (
        <input
          className={styles.input}
          type="text"
          value={Array.isArray(rule.value) ? (rule.value as string[]).join(', ') : String(rule.value ?? '')}
          onChange={(e) => onChange({ value: parseFilterValue(rule.field, rule.operator, e.target.value) })}
          placeholder={t('filter.valuePlaceholder')}
        />
      )}
      <button className={styles.removeBtn} onClick={onRemove} aria-label={t('dialog.removeCondition')}>
        &times;
      </button>
    </div>
  )
}
