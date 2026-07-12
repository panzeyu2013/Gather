import React, { useState, useCallback, useMemo, useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation } from '@tanstack/react-query'
import { exportApi } from '../../api/export'
import type { ExportOptions, ExportPreview, ExportProgressEvent } from '@gather/shared'
import styles from './Export.module.css'

export default function Export() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const [scope, setScope] = useState<ExportOptions['scope']>('session')
  const [format, setFormat] = useState<ExportOptions['format']>('original')
  const [quality, setQuality] = useState(85)
  const [maxDimension, setMaxDimension] = useState('')
  const [tiffCompression, setTiffCompression] = useState<ExportOptions['tiffCompression']>('lzw')
  const [namingPattern, setNamingPattern] = useState('{original}')
  const [destination, setDestination] = useState('')
  const [includeXmp, setIncludeXmp] = useState(true)
  const [watermarkEnabled, setWatermarkEnabled] = useState(false)
  const [watermarkText, setWatermarkText] = useState('')
  const [watermarkPosition, setWatermarkPosition] = useState<NonNullable<ExportOptions['watermark']>['position']>('bottom-right')
  const [watermarkOpacity, setWatermarkOpacity] = useState(0.5)
  const [watermarkFontSize, setWatermarkFontSize] = useState(24)
  const [preview, setPreview] = useState<ExportPreview | null>(null)
  const [progress, setProgress] = useState<ExportProgressEvent | null>(null)
  const [progressPercent, setProgressPercent] = useState(0)
  const [exportResult, setExportResult] = useState<string | null>(null)

  const buildOptions = useCallback((): ExportOptions => {
    const opts: ExportOptions = {
      scope,
      format,
      quality: format === 'jpeg' ? quality : undefined,
      maxDimension: maxDimension ? parseInt(maxDimension, 10) : undefined,
      tiffCompression: format === 'tiff' ? tiffCompression : undefined,
      naming: {
        pattern: namingPattern,
        counterStart: 1,
        dateFormat: 'YYYY-MM-DD',
      },
      includeXmp,
      destination,
      skipRemoved: scope === 'filtered',
    }

    if (watermarkEnabled && watermarkText) {
      opts.watermark = {
        type: 'text',
        content: watermarkText,
        position: watermarkPosition,
        opacity: watermarkOpacity,
        fontSize: watermarkFontSize,
      }
    }

    return opts
  }, [scope, format, quality, maxDimension, tiffCompression, namingPattern, includeXmp, destination, watermarkEnabled, watermarkText, watermarkPosition, watermarkOpacity, watermarkFontSize])

  const options = useMemo(buildOptions, [scope, format, quality, maxDimension, tiffCompression, namingPattern, includeXmp, destination, watermarkEnabled, watermarkText, watermarkPosition, watermarkOpacity, watermarkFontSize])

  const previewQuery = useQuery({
    queryKey: ['export-preview', sessionId, options],
    queryFn: () => exportApi.preview(sessionId!, options),
    enabled: false,
    retry: false,
  })

  const exportMutation = useMutation({
    mutationFn: () => exportApi.execute(sessionId!, options),
    onSuccess: (result) => {
      setExportResult(`Exported: ${result.exported}, Failed: ${result.failed}, Skipped: ${result.skipped}`)
      setProgress(null)
    },
  })

  const handlePreview = () => {
    setPreview(null)
    previewQuery.refetch().then((r) => {
      if (r.data) setPreview(r.data)
    }).catch(() => {
      setPreview(null)
    })
  }

  const handleExport = () => {
    setExportResult(null)
    setProgress(null)
    setProgressPercent(0)
    exportMutation.mutate()
  }

  const handleCancel = async () => {
    if (!sessionId) return
    await exportApi.cancel(sessionId)
    setProgress(null)
  }

  useEffect(() => {
    if (!window.gather?.onEvent) return
    const unsub = window.gather.onEvent('export:progress', (data) => {
      const evt = data as ExportProgressEvent
      setProgress(evt)
      if (evt.total > 0) {
        setProgressPercent(Math.round((evt.current / evt.total) * 100))
      }
    })
    return unsub
  }, [])

  const namingPreview = namingPattern
    .replace(/\{date\}/g, new Date().toISOString().slice(0, 10))
    .replace(/\{time\}/g, new Date().toTimeString().slice(0, 8).replace(/:/g, '-'))
    .replace(/\{counter\}/g, '0001')
    .replace(/\{original\}/g, 'IMG_1234')
    .replace(/\{session\}/g, sessionId ?? 'session')
    + (format === 'jpeg' ? '.jpg' : format === 'tiff' ? '.tiff' : '.ext')

  const needsDestination = !destination

  if (!sessionId) {
    return <div className={styles.page}><div className={styles.empty}>No session selected</div></div>
  }

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>Batch Export</h2>

      <div className={styles.section}>
        <label className={styles.label}>Scope</label>
        <select className={styles.select} value={scope} onChange={(e) => setScope(e.target.value as ExportOptions['scope'])}>
          <option value="session">Entire Session</option>
          <option value="filtered">Filtered</option>
          <option value="selected">Selected</option>
        </select>
      </div>

      <div className={styles.section}>
        <label className={styles.label}>Format</label>
        <select className={styles.select} value={format} onChange={(e) => setFormat(e.target.value as ExportOptions['format'])}>
          <option value="original">Original (Copy)</option>
          <option value="jpeg">JPEG</option>
          <option value="tiff">TIFF</option>
        </select>
      </div>

      {format === 'jpeg' && (
        <div className={styles.section}>
          <label className={styles.label}>Quality: {quality}</label>
          <input type="range" min={1} max={100} value={quality} onChange={(e) => setQuality(parseInt(e.target.value, 10))} className={styles.slider} />
        </div>
      )}

      {format === 'tiff' && (
        <div className={styles.section}>
          <label className={styles.label}>Compression</label>
          <select className={styles.select} value={tiffCompression} onChange={(e) => setTiffCompression(e.target.value as ExportOptions['tiffCompression'])}>
            <option value="none">None</option>
            <option value="lzw">LZW</option>
            <option value="deflate">Deflate</option>
          </select>
        </div>
      )}

      <div className={styles.section}>
        <label className={styles.label}>Max Dimension (px)</label>
        <input type="number" className={styles.input} value={maxDimension} onChange={(e) => setMaxDimension(e.target.value)} placeholder="No limit" min={1} />
      </div>

      <div className={styles.section}>
        <label className={styles.label}>
          <input type="checkbox" checked={watermarkEnabled} onChange={(e) => setWatermarkEnabled(e.target.checked)} />
          {' '}Watermark
        </label>
        {watermarkEnabled && (
          <div className={styles.subSection}>
            <input type="text" className={styles.input} value={watermarkText} onChange={(e) => setWatermarkText(e.target.value)} placeholder="Watermark text" />
            <select className={styles.select} value={watermarkPosition} onChange={(e) => setWatermarkPosition(e.target.value as NonNullable<ExportOptions['watermark']>['position'])}>
              <option value="bottom-right">Bottom Right</option>
              <option value="bottom-left">Bottom Left</option>
              <option value="center">Center</option>
            </select>
            <div className={styles.row}>
              <label className={styles.label}>Opacity: {watermarkOpacity.toFixed(1)}</label>
              <input type="range" min={0.1} max={1} step={0.1} value={watermarkOpacity} onChange={(e) => setWatermarkOpacity(parseFloat(e.target.value))} className={styles.slider} />
            </div>
            <div className={styles.row}>
              <label className={styles.label}>Font Size</label>
              <input type="number" className={styles.inputSm} value={watermarkFontSize} onChange={(e) => setWatermarkFontSize(parseInt(e.target.value, 10) || 24)} min={8} max={200} />
            </div>
          </div>
        )}
      </div>

      <div className={styles.section}>
        <label className={styles.label}>Naming Pattern</label>
        <input type="text" className={styles.input} value={namingPattern} onChange={(e) => setNamingPattern(e.target.value)} />
        <div className={styles.hint}>Available: {'{date}'} {'{time}'} {'{counter}'} {'{original}'} {'{session}'}</div>
        {namingPattern && (
          <div className={styles.preview}>Preview: {namingPreview}</div>
        )}
      </div>

      <div className={styles.section}>
        <label className={styles.label}>Destination Folder</label>
        <input type="text" className={styles.input} value={destination} onChange={(e) => setDestination(e.target.value)} placeholder="/path/to/export" />
      </div>

      <div className={styles.section}>
        <label className={styles.label}>
          <input type="checkbox" checked={includeXmp} onChange={(e) => setIncludeXmp(e.target.checked)} />
          {' '}Include XMP sidecars
        </label>
      </div>

      <div className={styles.actions}>
        <button className={styles.btn} onClick={handlePreview} disabled={previewQuery.isFetching || needsDestination}>
          {previewQuery.isFetching ? 'Calculating...' : 'Preview'}
        </button>
        <button className={`${styles.btn} ${styles.btnPrimary}`} onClick={handleExport} disabled={exportMutation.isPending || needsDestination}>
          {exportMutation.isPending ? 'Exporting...' : 'Export'}
        </button>
        <button className={styles.btn} onClick={handleCancel} disabled={!exportMutation.isPending}>
          Cancel
        </button>
      </div>

      {preview && (
        <div className={styles.previewBox}>
          <div className={styles.previewTitle}>Export Preview</div>
          <div>Files: {preview.totalFiles}</div>
          <div>Estimated Size: {(preview.totalSizeBytes / (1024 * 1024)).toFixed(1)} MB</div>
          {preview.freeSpaceBytes >= 0 && (
            <div className={preview.totalSizeBytes > preview.freeSpaceBytes ? styles.warning : ''}>
              Free Space: {(preview.freeSpaceBytes / (1024 * 1024 * 1024)).toFixed(1)} GB
              {preview.totalSizeBytes > preview.freeSpaceBytes && ' ⚠️ Insufficient space!'}
            </div>
          )}
        </div>
      )}
      {previewQuery.isError && (
        <div className={styles.error}>
          {previewQuery.error instanceof Error ? previewQuery.error.message : 'Preview failed'}
        </div>
      )}

      {(exportMutation.isPending || progress) && (
        <div className={styles.progress}>
          <div className={styles.progressBar}>
            <div
              className={styles.progressFill}
              style={{ width: `${exportMutation.isPending ? progressPercent : 100}%` }}
            />
          </div>
          <div className={styles.progressText}>
            {progress ? `${progress.current}/${progress.total} - ${progress.fileName}` : 'Exporting...'}
          </div>
        </div>
      )}

      {exportMutation.isError && (
        <div className={styles.error}>
          {exportMutation.error instanceof Error ? exportMutation.error.message : 'Export failed'}
        </div>
      )}

      {exportResult && (
        <div className={styles.success}>{exportResult}</div>
      )}
    </div>
  )
}
