import React, { useState, useEffect, useMemo, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation } from '@tanstack/react-query'
import { exportApi } from '../../api/export'
import { sessionApi } from '../../api/session'
import { useEvent } from '../../hooks/useEvent'
import type { ExportOptions, ExportPreview, ExportProgressData } from '@gather/shared'
import { useTranslation } from '../../locales'
import { translateError, translateErrorCode } from '../../utils/errors'
import styles from './Export.module.css'

/** Per-file export detail lines are composed in main as `filename: <code>` —
 * translate a GatherErrorCode tail so codes never leak into the result panel. */
function translateErrorLine(line: string): string {
  const separator = line.indexOf(': ')
  if (separator <= 0) return line
  return `${line.slice(0, separator)}: ${translateErrorCode(line.slice(separator + 2))}`
}

export default function Export() {
  const { t } = useTranslation()
  const { sessionId } = useParams<{ sessionId: string }>()
  const [format, setFormat] = useState<ExportOptions['format']>('original')
  const [variantPolicy, setVariantPolicy] =
    useState<NonNullable<ExportOptions['variantPolicy']>>('preferred')
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
  const [progress, setProgress] = useState<ExportProgressData | null>(null)
  const [progressPercent, setProgressPercent] = useState(0)
  const [exportResult, setExportResult] = useState<string | null>(null)

  const sessionQuery = useQuery({
    queryKey: ['session', sessionId],
    queryFn: () => sessionApi.get(sessionId!),
    enabled: Boolean(sessionId),
  })

  const options = useMemo((): ExportOptions => {
    const opts: ExportOptions = {
      scope: 'session',
      variantPolicy,
      format,
      quality: format === 'jpeg' ? quality : undefined,
      maxDimension: format === 'original' || !maxDimension
        ? undefined
        : parseInt(maxDimension, 10),
      tiffCompression: format === 'tiff' ? tiffCompression : undefined,
      naming: {
        pattern: namingPattern,
        counterStart: 1,
        dateFormat: 'YYYY-MM-DD',
      },
      includeXmp,
      destination,
    }

    if (format !== 'original' && watermarkEnabled && watermarkText) {
      opts.watermark = {
        type: 'text',
        content: watermarkText,
        position: watermarkPosition,
        opacity: watermarkOpacity,
        fontSize: watermarkFontSize,
      }
    }

    return opts
  }, [format, variantPolicy, quality, maxDimension, tiffCompression, namingPattern, includeXmp, destination, watermarkEnabled, watermarkText, watermarkPosition, watermarkOpacity, watermarkFontSize])

  const previewQuery = useQuery({
    queryKey: ['export-preview', sessionId, options],
    queryFn: () => exportApi.preview(sessionId!, options),
    enabled: false,
    retry: false,
  })

  const exportMutation = useMutation({
    mutationFn: () => exportApi.execute(sessionId!, options),
    onSuccess: (result) => {
      const errorDetails = result.errors.length > 0
        ? `\n${result.errors.slice(0, 3).map(translateErrorLine).join('\n')}`
        : ''
      setExportResult(
        t('export.result', {
          exported: result.exported,
          failed: result.failed,
          skipped: result.skipped,
        }) + errorDetails,
      )
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

  const handleSelectDestination = async () => {
    const directory = await window.gather.selectDirectory(t('dialog.selectExportFolder'))
    if (directory) setDestination(directory)
  }

  // export:progress fires once per file; coalescing through rAF caps re-renders
  // to one per animation frame (with the latest event), so the form/preview
  // area isn't re-rendered on every single file.
  const pendingProgressRef = useRef<ExportProgressData | null>(null)
  const progressFrameRef = useRef<number | null>(null)

  useEffect(() => () => {
    if (progressFrameRef.current !== null) {
      cancelAnimationFrame(progressFrameRef.current)
    }
  }, [])

  useEvent('export:progress', (data) => {
    const evt = data as ExportProgressData
    if (evt.sessionId !== sessionId) return
    pendingProgressRef.current = evt
    if (progressFrameRef.current !== null) return
    progressFrameRef.current = requestAnimationFrame(() => {
      progressFrameRef.current = null
      const latest = pendingProgressRef.current
      pendingProgressRef.current = null
      if (!latest) return
      setProgress(latest)
      if (latest.total > 0) {
        setProgressPercent(Math.round((latest.current / latest.total) * 100))
      }
    })
  }, Boolean(sessionId))

  const namingPreview = namingPattern
    .replace(/\{date\}/g, new Date().toISOString().slice(0, 10))
    .replace(/\{time\}/g, new Date().toTimeString().slice(0, 8).replace(/:/g, '-'))
    .replace(/\{counter\}/g, '0001')
    .replace(/\{original\}/g, 'IMG_1234')
    .replace(/\{session\}/g, sessionQuery.data?.name ?? t('export.workspaceName'))
    + (format === 'jpeg' ? '.jpg' : format === 'tiff' ? '.tiff' : `.${t('export.originalExt')}`)

  const needsDestination = !destination

  if (!sessionId) {
    return <div className={styles.page}><div className={styles.empty}>{t('export.noWorkspace')}</div></div>
  }

  return (
    <div className={styles.page}>
      <div className={styles.pageHeader}>
        <div>
          <h2 className={styles.title}>{t('export.title')}</h2>
          <p className={styles.pageDescription}>{t('export.description')}</p>
        </div>
      </div>

      <div className={styles.formGrid}>
      <section className={styles.card}>
        <h3 className={styles.cardTitle}>{t('export.fileSettings')}</h3>
        <div className={styles.section}>
        <label className={styles.label}>{t('export.format')}</label>
        <select className={styles.select} value={format} onChange={(e) => setFormat(e.target.value as ExportOptions['format'])}>
          <option value="original">{t('export.formatOriginal')}</option>
          <option value="jpeg">JPEG</option>
          <option value="tiff">TIFF</option>
        </select>
      </div>

      <div className={styles.section}>
        <label className={styles.label}>{t('export.variantPolicy')}</label>
        <select
          className={styles.select}
          value={variantPolicy}
          onChange={(event) => setVariantPolicy(
            event.target.value as NonNullable<ExportOptions['variantPolicy']>,
          )}
        >
          <option value="preferred">{t('export.variantPreferred')}</option>
          <option value="raw">{t('export.variantRaw')}</option>
          <option value="jpeg">{t('export.variantJpeg')}</option>
          <option value="all">{t('export.variantAll')}</option>
        </select>
      </div>

      {format === 'jpeg' && (
        <div className={styles.section}>
          <label className={styles.label}>{t('export.jpegQuality', { value: quality })}</label>
          <input type="range" min={1} max={100} value={quality} onChange={(e) => setQuality(parseInt(e.target.value, 10))} className={styles.slider} />
        </div>
      )}

      {format === 'tiff' && (
        <div className={styles.section}>
          <label className={styles.label}>{t('export.tiffCompression')}</label>
          <select className={styles.select} value={tiffCompression} onChange={(e) => setTiffCompression(e.target.value as ExportOptions['tiffCompression'])}>
            <option value="none">{t('export.tiffNone')}</option>
            <option value="lzw">LZW</option>
            <option value="deflate">{t('export.tiffDeflate')}</option>
          </select>
        </div>
      )}

      {format !== 'original' && (
        <div className={styles.section}>
          <label className={styles.label}>{t('export.maxDimension')}</label>
          <input type="number" className={styles.input} value={maxDimension} onChange={(e) => setMaxDimension(e.target.value)} placeholder={t('export.maxDimensionPlaceholder')} min={1} />
        </div>
      )}
      </section>

      {format !== 'original' && <section className={styles.card}>
        <h3 className={styles.cardTitle}>{t('export.watermark')}</h3>
      <div className={styles.section}>
        <label className={styles.label}>
          <input type="checkbox" checked={watermarkEnabled} onChange={(e) => setWatermarkEnabled(e.target.checked)} />
          {' '}{t('export.watermarkEnable')}
        </label>
        {watermarkEnabled && (
          <div className={styles.subSection}>
            <input type="text" className={styles.input} value={watermarkText} onChange={(e) => setWatermarkText(e.target.value)} placeholder={t('export.watermarkTextPlaceholder')} />
            <select className={styles.select} value={watermarkPosition} onChange={(e) => setWatermarkPosition(e.target.value as NonNullable<ExportOptions['watermark']>['position'])}>
              <option value="bottom-right">{t('export.watermarkBottomRight')}</option>
              <option value="bottom-left">{t('export.watermarkBottomLeft')}</option>
              <option value="center">{t('export.watermarkCenter')}</option>
            </select>
            <div className={styles.row}>
              <label className={styles.label}>{t('export.watermarkOpacity', { value: watermarkOpacity.toFixed(1) })}</label>
              <input type="range" min={0.1} max={1} step={0.1} value={watermarkOpacity} onChange={(e) => setWatermarkOpacity(parseFloat(e.target.value))} className={styles.slider} />
            </div>
            <div className={styles.row}>
              <label className={styles.label}>{t('export.watermarkFontSize')}</label>
              <input type="number" className={styles.inputSm} value={watermarkFontSize} onChange={(e) => setWatermarkFontSize(parseInt(e.target.value, 10) || 24)} min={8} max={200} />
            </div>
          </div>
        )}
      </div>
      </section>}

      <section className={`${styles.card} ${styles.cardWide}`}>
        <h3 className={styles.cardTitle}>{t('export.naming')}</h3>
      <div className={styles.section}>
        <label className={styles.label}>{t('export.namingPattern')}</label>
        <input type="text" className={styles.input} value={namingPattern} onChange={(e) => setNamingPattern(e.target.value)} />
        <div className={styles.hint}>{t('export.namingHint', { date: '{date}', time: '{time}', counter: '{counter}', original: '{original}', session: '{session}' })}</div>
        {namingPattern && (
          <div className={styles.preview}>{t('export.namingPreview', { preview: namingPreview })}</div>
        )}
      </div>

      <div className={styles.section}>
        <label className={styles.label}>{t('export.folder')}</label>
        <div className={styles.folderPicker}>
          <input type="text" className={styles.input} value={destination} onChange={(e) => setDestination(e.target.value)} placeholder={t('export.folderPlaceholder')} />
          <button type="button" className={styles.btn} onClick={handleSelectDestination}>{t('export.folderBtn')}</button>
        </div>
        <div className={styles.hint}>
          {t('export.folderHint')}
        </div>
      </div>

      <div className={styles.section}>
        <label className={styles.label}>
          <input type="checkbox" checked={includeXmp} onChange={(e) => setIncludeXmp(e.target.checked)} />
          {' '}{t('export.includeXmp')}
        </label>
      </div>
      </section>
      </div>

      <div className={styles.actions}>
        <button className={styles.btn} onClick={handlePreview} disabled={previewQuery.isFetching || needsDestination}>
          {previewQuery.isFetching ? t('export.previewing') : t('export.previewBtn')}
        </button>
        <button className={`${styles.btn} ${styles.btnPrimary}`} onClick={handleExport} disabled={exportMutation.isPending || needsDestination}>
          {exportMutation.isPending ? t('export.exporting') : t('export.exportingBtn')}
        </button>
        <button className={styles.btn} onClick={handleCancel} disabled={!exportMutation.isPending}>
          {t('export.cancelExport')}
        </button>
      </div>

      {preview && (
        <div className={styles.previewBox}>
          <div className={styles.previewTitle}>{t('export.previewTitle')}</div>
          <div>{t('export.fileCount', { count: preview.totalFiles })}</div>
          <div>{t('export.totalSize', { size: (preview.totalSizeBytes / (1024 * 1024)).toFixed(1) })}</div>
          {preview.freeSpaceBytes >= 0 && (
            <div className={preview.totalSizeBytes > preview.freeSpaceBytes ? styles.warning : ''}>
              {t('export.freeSpace', { size: (preview.freeSpaceBytes / (1024 * 1024 * 1024)).toFixed(1) })}
              {preview.totalSizeBytes > preview.freeSpaceBytes && t('export.spaceWarning')}
            </div>
          )}
        </div>
      )}
      {previewQuery.isError && (
        <div className={styles.error}>
          {previewQuery.error instanceof Error ? translateError(previewQuery.error) : t('error.exportPreviewFailed')}
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
            {progress ? t('export.progressText', { current: progress.current, total: progress.total, name: progress.fileName }) : t('export.preparing')}
          </div>
        </div>
      )}

      {exportMutation.isError && (
        <div className={styles.error}>
          {exportMutation.error instanceof Error ? translateError(exportMutation.error) : t('error.exportFailed')}
        </div>
      )}

      {exportResult && (
        <div className={styles.success}>{exportResult}</div>
      )}
    </div>
  )
}
