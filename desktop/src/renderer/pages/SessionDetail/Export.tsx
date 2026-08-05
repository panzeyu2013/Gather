import React, { useState, useMemo } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation } from '@tanstack/react-query'
import { exportApi } from '../../api/export'
import { sessionApi } from '../../api/session'
import { useEvent } from '../../hooks/useEvent'
import type { ExportOptions, ExportPreview, ExportProgressData } from '@gather/shared'
import styles from './Export.module.css'

export default function Export() {
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
        ? `\n${result.errors.slice(0, 3).join('\n')}`
        : ''
      setExportResult(
        `导出完成：成功 ${result.exported} 个，失败 ${result.failed} 个，跳过 ${result.skipped} 个${errorDetails}`,
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
    const directory = await window.gather.selectDirectory()
    if (directory) setDestination(directory)
  }

  useEvent('export:progress', (data) => {
    const evt = data as ExportProgressData
    if (evt.sessionId !== sessionId) return
    setProgress(evt)
    if (evt.total > 0) {
      setProgressPercent(Math.round((evt.current / evt.total) * 100))
    }
  }, Boolean(sessionId))

  const namingPreview = namingPattern
    .replace(/\{date\}/g, new Date().toISOString().slice(0, 10))
    .replace(/\{time\}/g, new Date().toTimeString().slice(0, 8).replace(/:/g, '-'))
    .replace(/\{counter\}/g, '0001')
    .replace(/\{original\}/g, 'IMG_1234')
    .replace(/\{session\}/g, sessionQuery.data?.name ?? '工作区')
    + (format === 'jpeg' ? '.jpg' : format === 'tiff' ? '.tiff' : '.原格式')

  const needsDestination = !destination

  if (!sessionId) {
    return <div className={styles.page}><div className={styles.empty}>未选择工作区</div></div>
  }

  return (
    <div className={styles.page}>
      <div className={styles.pageHeader}>
        <div>
          <h2 className={styles.title}>批量导出</h2>
          <p className={styles.pageDescription}>按统一格式、命名规则和目标目录导出当前工作区中的照片。</p>
        </div>
      </div>

      <div className={styles.formGrid}>
      <section className={styles.card}>
        <h3 className={styles.cardTitle}>文件设置</h3>
        <div className={styles.section}>
        <label className={styles.label}>文件格式</label>
        <select className={styles.select} value={format} onChange={(e) => setFormat(e.target.value as ExportOptions['format'])}>
          <option value="original">保持原格式（复制）</option>
          <option value="jpeg">JPEG</option>
          <option value="tiff">TIFF</option>
        </select>
      </div>

      <div className={styles.section}>
        <label className={styles.label}>RAW / JPEG 变体</label>
        <select
          className={styles.select}
          value={variantPolicy}
          onChange={(event) => setVariantPolicy(
            event.target.value as NonNullable<ExportOptions['variantPolicy']>,
          )}
        >
          <option value="preferred">首选文件（优先 RAW）</option>
          <option value="raw">仅 RAW</option>
          <option value="jpeg">仅 JPEG</option>
          <option value="all">全部物理变体</option>
        </select>
      </div>

      {format === 'jpeg' && (
        <div className={styles.section}>
          <label className={styles.label}>JPEG 质量：{quality}</label>
          <input type="range" min={1} max={100} value={quality} onChange={(e) => setQuality(parseInt(e.target.value, 10))} className={styles.slider} />
        </div>
      )}

      {format === 'tiff' && (
        <div className={styles.section}>
          <label className={styles.label}>TIFF 压缩</label>
          <select className={styles.select} value={tiffCompression} onChange={(e) => setTiffCompression(e.target.value as ExportOptions['tiffCompression'])}>
            <option value="none">不压缩</option>
            <option value="lzw">LZW</option>
            <option value="deflate">Deflate 压缩</option>
          </select>
        </div>
      )}

      {format !== 'original' && (
        <div className={styles.section}>
          <label className={styles.label}>最长边（像素）</label>
          <input type="number" className={styles.input} value={maxDimension} onChange={(e) => setMaxDimension(e.target.value)} placeholder="不限制" min={1} />
        </div>
      )}
      </section>

      {format !== 'original' && <section className={styles.card}>
        <h3 className={styles.cardTitle}>水印</h3>
      <div className={styles.section}>
        <label className={styles.label}>
          <input type="checkbox" checked={watermarkEnabled} onChange={(e) => setWatermarkEnabled(e.target.checked)} />
          {' '}启用文字水印
        </label>
        {watermarkEnabled && (
          <div className={styles.subSection}>
            <input type="text" className={styles.input} value={watermarkText} onChange={(e) => setWatermarkText(e.target.value)} placeholder="输入水印文字" />
            <select className={styles.select} value={watermarkPosition} onChange={(e) => setWatermarkPosition(e.target.value as NonNullable<ExportOptions['watermark']>['position'])}>
              <option value="bottom-right">右下角</option>
              <option value="bottom-left">左下角</option>
              <option value="center">居中</option>
            </select>
            <div className={styles.row}>
              <label className={styles.label}>不透明度：{watermarkOpacity.toFixed(1)}</label>
              <input type="range" min={0.1} max={1} step={0.1} value={watermarkOpacity} onChange={(e) => setWatermarkOpacity(parseFloat(e.target.value))} className={styles.slider} />
            </div>
            <div className={styles.row}>
              <label className={styles.label}>字号</label>
              <input type="number" className={styles.inputSm} value={watermarkFontSize} onChange={(e) => setWatermarkFontSize(parseInt(e.target.value, 10) || 24)} min={8} max={200} />
            </div>
          </div>
        )}
      </div>
      </section>}

      <section className={`${styles.card} ${styles.cardWide}`}>
        <h3 className={styles.cardTitle}>命名与位置</h3>
      <div className={styles.section}>
        <label className={styles.label}>文件命名规则</label>
        <input type="text" className={styles.input} value={namingPattern} onChange={(e) => setNamingPattern(e.target.value)} />
        <div className={styles.hint}>可用变量：{'{date}'} 日期　{'{time}'} 时间　{'{counter}'} 序号　{'{original}'} 原文件名　{'{session}'} 工作区名</div>
        {namingPattern && (
          <div className={styles.preview}>文件名预览：{namingPreview}</div>
        )}
      </div>

      <div className={styles.section}>
        <label className={styles.label}>导出文件夹</label>
        <div className={styles.folderPicker}>
          <input type="text" className={styles.input} value={destination} onChange={(e) => setDestination(e.target.value)} placeholder="请选择导出文件夹" />
          <button type="button" className={styles.btn} onClick={handleSelectDestination}>选择文件夹</button>
        </div>
        <div className={styles.hint}>
          请选择导出文件夹。不要选择工作区导入目录，否则导出的文件会被重新导入当前工作区。
        </div>
      </div>

      <div className={styles.section}>
        <label className={styles.label}>
          <input type="checkbox" checked={includeXmp} onChange={(e) => setIncludeXmp(e.target.checked)} />
          {' '}同时导出 XMP 边车文件
        </label>
      </div>
      </section>
      </div>

      <div className={styles.actions}>
        <button className={styles.btn} onClick={handlePreview} disabled={previewQuery.isFetching || needsDestination}>
          {previewQuery.isFetching ? '正在计算...' : '预览导出'}
        </button>
        <button className={`${styles.btn} ${styles.btnPrimary}`} onClick={handleExport} disabled={exportMutation.isPending || needsDestination}>
          {exportMutation.isPending ? '正在导出...' : '开始导出'}
        </button>
        <button className={styles.btn} onClick={handleCancel} disabled={!exportMutation.isPending}>
          取消导出
        </button>
      </div>

      {preview && (
        <div className={styles.previewBox}>
          <div className={styles.previewTitle}>导出预览</div>
          <div>文件数量：{preview.totalFiles}</div>
          <div>预计占用：{(preview.totalSizeBytes / (1024 * 1024)).toFixed(1)} MB</div>
          {preview.freeSpaceBytes >= 0 && (
            <div className={preview.totalSizeBytes > preview.freeSpaceBytes ? styles.warning : ''}>
              可用空间：{(preview.freeSpaceBytes / (1024 * 1024 * 1024)).toFixed(1)} GB
              {preview.totalSizeBytes > preview.freeSpaceBytes && ' ⚠️ 空间不足'}
            </div>
          )}
        </div>
      )}
      {previewQuery.isError && (
        <div className={styles.error}>
          {previewQuery.error instanceof Error ? previewQuery.error.message : '生成导出预览失败'}
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
            {progress ? `${progress.current}/${progress.total} · ${progress.fileName}` : '正在准备导出...'}
          </div>
        </div>
      )}

      {exportMutation.isError && (
        <div className={styles.error}>
          {exportMutation.error instanceof Error ? exportMutation.error.message : '导出失败'}
        </div>
      )}

      {exportResult && (
        <div className={styles.success}>{exportResult}</div>
      )}
    </div>
  )
}
