import React, { useEffect, useState } from 'react'
import { useSettingsStore } from '../../stores/settingsStore'
import Loading from '../../components/Loading/Loading'
import SliderInput from '../../components/SliderInput/SliderInput'
import styles from './Settings.module.css'

interface SettingDefinition {
  key: string
  label: string
  type: 'text' | 'number' | 'select'
  description: string
}

interface SettingGroup {
  title: string
  settings: SettingDefinition[]
}

const GROUPS: SettingGroup[] = [
  {
    title: '缓存',
    settings: [
      { key: 'memory_cache_size', label: '内存缓存条目数', type: 'number', description: '内存中缓存的缩略图最大数量' },
      { key: 'disk_cache_dir', label: '磁盘缓存目录', type: 'text', description: '磁盘缓存存储路径（留空使用默认）' },
      { key: 'disk_cache_max_size_gb', label: '磁盘缓存上限 (GB)', type: 'number', description: '磁盘缓存占用硬盘的最大空间' },
      { key: 'disk_cache_eviction_policy', label: '淘汰策略', type: 'select', description: 'lru=LRU（最近最少使用）, fifo=FIFO（先进先出）, lfu=LFU（最不经常使用）' },
    ],
  },
  {
    title: '图片处理',
    settings: [
      { key: 'thumbnail_size', label: '缩略图尺寸', type: 'number', description: '缩略图的宽高像素值（320-5120）' },
      { key: 'thumbnail_quality', label: '缩略图质量', type: 'number', description: '缩略图的 JPEG 压缩质量 (0-100)' },
      { key: 'thumbnail_concurrency', label: '缩略图生成并发数', type: 'number', description: '同时生成缩略图的线程数，0=自动（最大CPU核心数-1）' },
      { key: 'face_thumbnail_size', label: '人脸缩略图尺寸', type: 'number', description: '人脸缩略图的宽高像素值' },
      { key: 'face_thumbnail_quality', label: '人脸缩略图质量', type: 'number', description: '人脸缩略图的 JPEG 压缩质量 (0-100)' },
    ],
  },
  {
    title: '数据库',
    settings: [
      { key: 'db_cache_size_mb', label: '缓存大小 (MB)', type: 'number', description: 'SQLite 数据库的页面缓存大小' },
      { key: 'db_synchronous', label: '同步模式', type: 'select', description: 'off=OFF（关闭）, normal=NORMAL（正常）, full=FULL（完整）' },
    ],
  },
  {
    title: 'Capture One 集成',
    settings: [
      { key: 'c1_timeout_ms', label: '超时时间 (ms)', type: 'number', description: '与 Capture One 通信的超时毫秒数' },
      { key: 'c1_retries', label: '重试次数', type: 'number', description: '与 Capture One 通信的最大重试次数' },
      { key: 'c1_reload_delay_ms', label: '重载延迟 (ms)', type: 'number', description: '重载元数据后的等待延迟毫秒数' },
    ],
  },
  {
    title: '轮询',
    settings: [
      { key: 'poll_max_retries_sim', label: '相似度最大重试', type: 'number', description: '相似度分析轮询的最大重试次数' },
      { key: 'poll_max_retries_fkw', label: '人脸最大重试', type: 'number', description: '人脸分析轮询的最大重试次数' },
      { key: 'poll_interval_sim_ms', label: '相似度轮询间隔 (ms)', type: 'number', description: '相似度分析轮询的间隔毫秒数' },
      { key: 'poll_interval_fkw_ms', label: '人脸轮询间隔 (ms)', type: 'number', description: '人脸分析轮询的间隔毫秒数' },
    ],
  },
  {
    title: '哈希',
    settings: [
      { key: 'hash_chunk_size', label: '分块大小', type: 'number', description: '图像哈希计算的分块大小' },
    ],
  },
]

function parseSelectOptions(description: string): { value: string; label: string }[] {
  return description.split(',').map((part) => {
    const [value, ...rest] = part.trim().split('=')
    return { value: value.trim(), label: rest.join('=').trim() }
  })
}

export default function SettingsPage() {
  const settings = useSettingsStore((s) => s.settings)
  const loading = useSettingsStore((s) => s.loading)
  const mlStatus = useSettingsStore((s) => s.mlStatus)
  const mlStatusLoading = useSettingsStore((s) => s.mlStatusLoading)
  const load = useSettingsStore((s) => s.load)
  const loadMlStatus = useSettingsStore((s) => s.loadMlStatus)
  const setSetting = useSettingsStore((s) => s.setSetting)
  const resetToDefaults = useSettingsStore((s) => s.resetToDefaults)

  const [openSections, setOpenSections] = useState<Set<string>>(() => new Set(GROUPS.map((g) => g.title).concat('人脸分析')))
  const [openSubSections, setOpenSubSections] = useState<Set<string>>(new Set())
  const [downloadProgress, setDownloadProgress] = useState<{ filename: string; percent: number } | null>(null)
  const [downloadState, setDownloadState] = useState<'idle' | 'downloading' | 'done' | 'error'>('idle')
  const backendManual = mlStatus ? !mlStatus.isAuto : false
  const cpuCount = navigator.hardwareConcurrency || 4
  const maxConcurrency = Math.max(1, cpuCount - 1)

  useEffect(() => {
    load()
    loadMlStatus()
  }, [load, loadMlStatus])

  useEffect(() => {
    if (downloadState !== 'downloading') return
    const unsub = window.gather.onModelDownloadProgress((data) => {
      const p = data as { filename: string; percent: number }
      setDownloadProgress(p)
      if (p.percent >= 100) {
        setDownloadState('done')
        setTimeout(() => {
          setDownloadState('idle')
          setDownloadProgress(null)
          loadMlStatus()
        }, 2000)
      }
    })
    return unsub
  }, [downloadState, loadMlStatus])

  const handleInstallModels = async () => {
    setDownloadState('downloading')
    setDownloadProgress(null)
    try {
      await window.gather.downloadDefaultModels()
    } catch {
      setDownloadState('error')
      setTimeout(() => setDownloadState('idle'), 3000)
    }
  }

  const toggleSection = (title: string) => {
    setOpenSections((prev) => {
      const next = new Set(prev)
      if (next.has(title)) next.delete(title)
      else next.add(title)
      return next
    })
  }

  const toggleSubSection = (title: string) => {
    setOpenSubSections((prev) => {
      const next = new Set(prev)
      if (next.has(title)) next.delete(title)
      else next.add(title)
      return next
    })
  }

  const handleSliderChange = (key: string) => (value: number) => {
    setSetting(key, String(value))
  }

  const getVal = (key: string, fallback: string) => {
    const v = settings[key]
    return v !== undefined && v !== '' ? v : fallback
  }

  if (loading) {
    return (
      <div className={styles.page}>
        <div className={styles.header}>
          <h1 className={styles.title}>设置</h1>
        </div>
        <div className={styles.loading}>
          <Loading />
        </div>
      </div>
    )
  }

  const faceSection = (
    <div key="人脸分析" className={styles.section}>
      <button className={styles.sectionHeader} onClick={() => toggleSection('人脸分析')}>
        <span className={`${styles.chevron} ${openSections.has('人脸分析') ? styles.chevronOpen : ''}`}>
          &#9654;
        </span>
        人脸分析
      </button>

      {openSections.has('人脸分析') && (
        <div className={styles.sectionBody}>
          <div className={styles.subSectionLabel}>常规参数</div>

          <div className={styles.settingRow}>
            <div className={styles.settingInfo}>
              <p className={styles.settingLabel}>检测敏感度</p>
              <p className={styles.settingDesc}>低于此置信度的人脸将被忽略</p>
            </div>
            <div className={styles.sliderInput}>
              <SliderInput
                value={parseFloat(getVal('detect_confidence', '0.5'))}
                min={0}
                max={1}
                step={0.05}
                onChange={handleSliderChange('detect_confidence')}
              />
            </div>
          </div>

          <div className={styles.settingRow}>
            <div className={styles.settingInfo}>
              <p className={styles.settingLabel}>聚类半径</p>
              <p className={styles.settingDesc}>值越大，不同人脸越容易被归为同一人</p>
            </div>
            <div className={styles.sliderInput}>
              <SliderInput
                value={parseFloat(getVal('default_eps', '0.6'))}
                min={0}
                max={1}
                step={0.05}
                onChange={handleSliderChange('default_eps')}
              />
            </div>
          </div>

          <div className={styles.settingRow}>
            <div className={styles.settingInfo}>
              <p className={styles.settingLabel}>最小样本数</p>
              <p className={styles.settingDesc}>一个人至少出现 N 张照片才形成聚类</p>
            </div>
            <div className={styles.sliderInput}>
              <SliderInput
                value={parseInt(getVal('default_min_samples', '2'), 10)}
                min={1}
                max={20}
                step={1}
                onChange={handleSliderChange('default_min_samples')}
              />
            </div>
          </div>

          {/* 模型与运行 */}
          <div className={styles.settingDivider} />
          <button className={styles.subSectionHeader} onClick={() => toggleSubSection('模型与运行')}>
            <span className={`${styles.subChevron} ${openSubSections.has('模型与运行') ? styles.subChevronOpen : ''}`}>
              &#9654;
            </span>
            模型与运行
            <span className={styles.subSectionHint}>
              {mlStatusLoading ? '检测中…' : mlStatus ? (mlStatus.detectorModel.exists && mlStatus.encoderModel.exists ? '✓' : '⚠') : ''}
            </span>
          </button>

          {openSubSections.has('模型与运行') && (
            <div className={styles.subSectionBody}>
              {mlStatusLoading ? (
                <div className={styles.statusLoading}>正在检测模型状态…</div>
              ) : mlStatus ? (
                <>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>检测模型</p>
                    </div>
                    <div className={styles.modelStatus}>
                      <span className={mlStatus.detectorModel.exists ? styles.statusOk : styles.statusFail}>
                        {mlStatus.detectorModel.exists ? '✓ 正常' : '✗ 未找到'}
                      </span>
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>编码模型</p>
                    </div>
                    <div className={styles.modelStatus}>
                      <span className={mlStatus.encoderModel.exists ? styles.statusOk : styles.statusFail}>
                        {mlStatus.encoderModel.exists ? '✓ 正常' : '✗ 未找到'}
                      </span>
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>检测模型路径</p>
                      <p className={styles.settingDesc}>{mlStatus.detectorModel.resolvedPath}</p>
                    </div>
                    <div className={styles.pathRow}>
                      <input
                        className={styles.pathInput}
                        type="text"
                        value={getVal('detector_model_path', 'models/face_detector.onnx')}
                        onChange={(e) => setSetting('detector_model_path', e.target.value)}
                        onBlur={() => loadMlStatus()}
                      />
                      <button
                        className={styles.pathBtn}
                        onClick={() => window.gather.openDirectory(mlStatus.detectorModel.resolvedPath.replace(/\/[^/]+$/, ''))}
                      >
                        打开
                      </button>
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>编码模型路径</p>
                      <p className={styles.settingDesc}>{mlStatus.encoderModel.resolvedPath}</p>
                    </div>
                    <div className={styles.pathRow}>
                      <input
                        className={styles.pathInput}
                        type="text"
                        value={getVal('encoder_model_path', 'models/face_encoder.onnx')}
                        onChange={(e) => setSetting('encoder_model_path', e.target.value)}
                        onBlur={() => loadMlStatus()}
                      />
                      <button
                        className={styles.pathBtn}
                        onClick={() => window.gather.openDirectory(mlStatus.encoderModel.resolvedPath.replace(/\/[^/]+$/, ''))}
                      >
                        打开
                      </button>
                    </div>
                  </div>

                  {(!mlStatus.detectorModel.exists || !mlStatus.encoderModel.exists) && (
                    <div className={styles.installBanner}>
                      <p>模型文件未找到。请将 ONNX 模型文件放入以下文件夹：<br />{mlStatus.modelResourcesDir}</p>
                      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                        <button className={styles.installBtn} onClick={() => window.gather.openDirectory(mlStatus.modelResourcesDir)}>
                          打开模型文件夹
                        </button>
                        <button
                          className={styles.installBtn}
                          onClick={handleInstallModels}
                          disabled={downloadState === 'downloading'}
                        >
                          {downloadState === 'downloading' ? '下载中…' : downloadState === 'error' ? '下载失败' : '自动下载模型'}
                        </button>
                      </div>
                      {downloadProgress && (
                        <div style={{ marginTop: 8, fontSize: 12, color: 'var(--color-text-secondary)' }}>
                          {downloadProgress.filename}: {Math.round(downloadProgress.percent)}%
                        </div>
                      )}
                    </div>
                  )}
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>模型信息</p>
                    </div>
                    <div className={styles.modelInfoText}>
                      检测输入 {mlStatus.modelInfo.detectInputSize}×{mlStatus.modelInfo.detectInputSize}
                      ，编码输入 {mlStatus.modelInfo.encoderInputSize}×{mlStatus.modelInfo.encoderInputSize}
                      ，特征维度 {mlStatus.modelInfo.embeddingDim}
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>运行后端</p>
                      <p className={styles.settingDesc}>
                        {mlStatus.isAuto
                          ? `自动适配（${mlStatus.autoBackendLabel}）`
                          : `手动：${mlStatus.provider}`}
                      </p>
                    </div>
                    <div className={styles.backendControl}>
                      <span className={styles.backendLabel}>
                        {mlStatus.isAuto ? mlStatus.autoBackendLabel : mlStatus.provider}
                      </span>
                      <button
                        className={styles.linkBtn}
                        onClick={async () => {
                          if (backendManual) {
                            await setSetting('onnx_provider', 'auto')
                          } else {
                            await setSetting('onnx_provider', mlStatus.autoBackend)
                          }
                          loadMlStatus()
                        }}
                      >
                        {backendManual ? '恢复自动' : '手动切换'}
                      </button>
                      {backendManual && (
                        <select
                          className={styles.backendSelect}
                          value={mlStatus.provider}
                          onChange={async (e) => {
                            await setSetting('onnx_provider', e.target.value)
                            loadMlStatus()
                          }}
                        >
                          {mlStatus.availableBackends.map((b) => (
                            <option key={b.value} value={b.value}>{b.label}</option>
                          ))}
                        </select>
                      )}
                    </div>
                  </div>
                </>
              ) : (
                <div className={styles.statusLoading}>无法获取模型状态</div>
              )}
            </div>
          )}

          {/* 高级参数 */}
          <button className={styles.subSectionHeader} onClick={() => toggleSubSection('高级参数')}>
            <span className={`${styles.subChevron} ${openSubSections.has('高级参数') ? styles.subChevronOpen : ''}`}>
              &#9654;
            </span>
            高级参数
          </button>

          {openSubSections.has('高级参数') && (
            <div className={styles.subSectionBody}>
              <div className={styles.settingRow}>
                <div className={styles.settingInfo}>
                  <p className={styles.settingLabel}>NMS 阈值</p>
                  <p className={styles.settingDesc}>重叠人脸的过滤阈值</p>
                </div>
                <div className={styles.sliderInput}>
                  <SliderInput
                    value={parseFloat(getVal('nms_threshold', '0.4'))}
                    min={0}
                    max={1}
                    step={0.05}
                    onChange={handleSliderChange('nms_threshold')}
                  />
                </div>
              </div>
              <div className={styles.settingRow}>
                <div className={styles.settingInfo}>
                  <p className={styles.settingLabel}>最大检测数</p>
                  <p className={styles.settingDesc}>单张图片最多检测的人脸数</p>
                </div>
                <div className={styles.sliderInput}>
                  <SliderInput
                    value={parseInt(getVal('max_detections', '100'), 10)}
                    min={1}
                    max={500}
                    step={1}
                    onChange={handleSliderChange('max_detections')}
                  />
                </div>
              </div>
              <div className={styles.settingRow}>
                <div className={styles.settingInfo}>
                  <p className={styles.settingLabel}>ONNX 线程</p>
                  <p className={styles.settingDesc}>推理并行线程数</p>
                </div>
                <div className={styles.sliderInput}>
                  <SliderInput
                    value={parseInt(getVal('onnx_threads', '4'), 10)}
                    min={1}
                    max={16}
                    step={1}
                    onChange={handleSliderChange('onnx_threads')}
                  />
                </div>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>设置</h1>
        <button className={styles.resetBtn} onClick={resetToDefaults}>
          重置为默认值
        </button>
      </div>

      {faceSection}

      {GROUPS.map((group) => (
        <div key={group.title} className={styles.section}>
          <button
            className={styles.sectionHeader}
            onClick={() => toggleSection(group.title)}
          >
            <span className={`${styles.chevron} ${openSections.has(group.title) ? styles.chevronOpen : ''}`}>
              &#9654;
            </span>
            {group.title}
          </button>

          {openSections.has(group.title) && (
            <div className={styles.sectionBody}>
              {group.settings.map((setting) => {
                const currentValue = settings[setting.key] ?? ''

                if (setting.type === 'select') {
                  const options = parseSelectOptions(setting.description)
                  return (
                    <div key={setting.key} className={styles.settingRow}>
                      <div className={styles.settingInfo}>
                        <p className={styles.settingLabel}>{setting.label}</p>
                        <p className={styles.settingDesc}>{parseSelectOptions(setting.description).map(o => o.label).join('、')}</p>
                      </div>
                      <div className={styles.settingInput}>
                        <select
                          className={styles.select}
                          value={currentValue}
                          onChange={(e) => setSetting(setting.key, e.target.value)}
                        >
                          <option value="" disabled>请选择</option>
                          {options.map((opt) => (
                            <option key={opt.value} value={opt.value}>{opt.label}</option>
                          ))}
                        </select>
                      </div>
                    </div>
                  )
                }

                return (
                  <div key={setting.key} className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{setting.label}</p>
                      <p className={styles.settingDesc}>{setting.description}</p>
                    </div>
                    <div className={styles.settingInput}>
                      <input
                        className={styles.input}
                        type={setting.type === 'number' ? 'number' : 'text'}
                        value={currentValue}
                        min={setting.key === 'thumbnail_size' ? 320 : setting.key === 'thumbnail_concurrency' ? 1 : undefined}
                        max={setting.key === 'thumbnail_size' ? 5120 : setting.key === 'thumbnail_concurrency' ? maxConcurrency : undefined}
                        onChange={(e) => setSetting(setting.key, e.target.value)}
                      />
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      ))}
    </div>
  )
}
