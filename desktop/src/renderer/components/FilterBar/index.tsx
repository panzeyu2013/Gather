import React, { useState, useCallback } from 'react'
import type { FilterGroup, FilterRule } from '@gather/shared'
import { FILTER_FIELDS, getFilterOperators, parseFilterValue } from './filter-constants'
import styles from './FilterBar.module.css'

interface FilterBarProps {
  sessionId: string
  onFilterChange: (criteria: FilterGroup | null) => void
}

interface ActiveRule {
  id: number
  field: string
  operator: FilterRule['operator']
  value: string
}

let nextId = 1

export default function FilterBar({ sessionId: _sessionId, onFilterChange }: FilterBarProps) {
  const [rules, setRules] = useState<ActiveRule[]>([])
  const [logic, setLogic] = useState<'and' | 'or'>('and')
  const [editing, setEditing] = useState(false)
  const [newField, setNewField] = useState(FILTER_FIELDS[0].value)
  const [newOperator, setNewOperator] = useState<FilterRule['operator']>('contains')
  const [newValue, setNewValue] = useState('')

  const emitChange = useCallback(
    (currentRules: ActiveRule[], currentLogic: 'and' | 'or') => {
      if (currentRules.length === 0) {
        onFilterChange(null)
        return
      }
      const conditions: FilterRule[] = currentRules.map((r) => ({
        field: r.field,
        operator: r.operator,
        value: parseFilterValue(r.field, r.operator, r.value),
      }))
      onFilterChange({ logic: currentLogic, conditions })
    },
    [onFilterChange],
  )

  const addRule = useCallback(() => {
    if (!newValue.trim() && newField !== 'exists') return
    const updated = [
      ...rules,
      { id: nextId++, field: newField, operator: newOperator, value: newValue.trim() },
    ]
    setRules(updated)
    setNewValue('')
    setEditing(false)
    emitChange(updated, logic)
  }, [rules, logic, newField, newOperator, newValue, emitChange])

  const removeRule = useCallback(
    (id: number) => {
      const updated = rules.filter((r) => r.id !== id)
      setRules(updated)
      emitChange(updated, logic)
    },
    [rules, logic, emitChange],
  )

  const toggleLogic = useCallback(() => {
    const next = logic === 'and' ? 'or' : 'and'
    setLogic(next)
    emitChange(rules, next)
  }, [logic, rules, emitChange])

  const clearAll = useCallback(() => {
    setRules([])
    setLogic('and')
    setEditing(false)
    onFilterChange(null)
  }, [onFilterChange])

  return (
    <div className={styles.container}>
      <div className={styles.chips}>
        {rules.map((rule) => (
          <span key={rule.id} className={styles.chip}>
            <span className={styles.chipField}>{rule.field}</span>
            <span className={styles.chipOp}>{rule.operator}</span>
            <span className={styles.chipValue}>{rule.value}</span>
            <button
              className={styles.chipRemove}
              onClick={() => removeRule(rule.id)}
              aria-label="Remove filter"
            >
              &times;
            </button>
          </span>
        ))}
        {rules.length > 1 && (
          <button className={styles.logicToggle} onClick={toggleLogic}>
            {logic.toUpperCase()}
          </button>
        )}
      </div>

      <div className={styles.actions}>
        {editing ? (
          <div className={styles.editRow}>
            <select
              className={styles.select}
              value={newField}
              onChange={(e) => {
                setNewField(e.target.value)
                setNewOperator(getFilterOperators(e.target.value)[0].value)
              }}
            >
              {FILTER_FIELDS.map((f) => (
                <option key={f.value} value={f.value}>
                  {f.label}
                </option>
              ))}
            </select>
            <select
              className={styles.select}
              value={newOperator}
              onChange={(e) => setNewOperator(e.target.value as FilterRule['operator'])}
            >
              {getFilterOperators(newField).map((op) => (
                <option key={op.value} value={op.value}>
                  {op.label}
                </option>
              ))}
            </select>
            {newOperator !== 'exists' && (
              <input
                className={styles.input}
                type="text"
                value={newValue}
                onChange={(e) => setNewValue(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') addRule()
                }}
                placeholder="value"
                autoFocus
              />
            )}
            <button className={styles.addBtn} onClick={addRule}>
              Add
            </button>
            <button className={styles.cancelBtn} onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        ) : (
          <button className={styles.addRuleBtn} onClick={() => setEditing(true)}>
            + Add Filter
          </button>
        )}
        {rules.length > 0 && (
          <button className={styles.clearBtn} onClick={clearAll}>
            Clear All
          </button>
        )}
      </div>
    </div>
  )
}
