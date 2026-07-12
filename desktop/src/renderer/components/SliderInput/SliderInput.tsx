import React, { useCallback } from 'react'
import styles from './SliderInput.module.css'

interface SliderInputProps {
  value: number
  min: number
  max: number
  step: number
  onChange: (value: number) => void
}

export default function SliderInput({ value, min, max, step, onChange }: SliderInputProps) {
  const handleSlider = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      onChange(parseFloat(e.target.value))
    },
    [onChange],
  )

  const handleNumber = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const raw = e.target.value
      if (raw === '') return
      const n = parseFloat(raw)
      if (isNaN(n)) return
      onChange(n)
    },
    [onChange],
  )

  const handleBlur = useCallback(() => {
    const clamped = Math.min(max, Math.max(min, value))
    if (clamped !== value) onChange(clamped)
  }, [value, min, max, onChange])

  const pct = ((value - min) / (max - min)) * 100

  return (
    <div className={styles.wrapper}>
      <input
        type="range"
        className={styles.slider}
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={handleSlider}
        style={{ background: `linear-gradient(to right, var(--color-primary) 0%, var(--color-primary) ${pct}%, var(--color-border) ${pct}%, var(--color-border) 100%)` }}
      />
      <input
        type="number"
        className={styles.number}
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={handleNumber}
        onBlur={handleBlur}
      />
    </div>
  )
}
