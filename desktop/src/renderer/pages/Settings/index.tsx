import React, { useEffect, useId, useState } from 'react'
import { useSettingsStore } from '../../stores/settingsStore'
import Loading from '../../components/Loading/Loading'
import SliderInput from '../../components/SliderInput/SliderInput'
import C1HealthPanel from './C1HealthPanel'
import { settingsApi, type AppLocale } from '../../api/settings'
import { useTranslation, detectLanguage, initI18n, type TranslationKey } from '../../locales'
import { translatePhase } from '../../utils/progress'
import styles from './Settings.module.css'

interface SettingDefinition {
  key: string
  labelKey: TranslationKey
  type: 'text' | 'number' | 'select'
  descriptionKey: TranslationKey
}

interface SettingGroup {
  id: string
  titleKey: TranslationKey
  settings: SettingDefinition[]
}

const GROUPS: SettingGroup[] = [
  {
    id: 'cache',
    titleKey: 'settings.group.cache',
    settings: [
      { key: 'memory_cache_size', labelKey: 'settings.cache.memoryCacheSize', type: 'number', descriptionKey: 'settings.cache.memoryCacheSizeDesc' },
      { key: 'memory_cache_max_size_mb', labelKey: 'settings.cache.memoryCacheMaxMb', type: 'number', descriptionKey: 'settings.cache.memoryCacheMaxMbDesc' },
      { key: 'disk_cache_dir', labelKey: 'settings.cache.diskCacheDir', type: 'text', descriptionKey: 'settings.cache.diskCacheDirDesc' },
      { key: 'disk_cache_max_size_gb', labelKey: 'settings.cache.diskCacheMaxGb', type: 'number', descriptionKey: 'settings.cache.diskCacheMaxGbDesc' },
      { key: 'disk_cache_eviction_policy', labelKey: 'settings.cache.evictionPolicy', type: 'select', descriptionKey: 'settings.cache.evictionPolicyDesc' },
    ],
  },
  {
    id: 'image',
    titleKey: 'settings.group.image',
    settings: [
      { key: 'thumbnail_size', labelKey: 'settings.image.thumbnailSize', type: 'number', descriptionKey: 'settings.image.thumbnailSizeDesc' },
      { key: 'thumbnail_quality', labelKey: 'settings.image.thumbnailQuality', type: 'number', descriptionKey: 'settings.image.thumbnailQualityDesc' },
      { key: 'thumbnail_concurrency', labelKey: 'settings.image.thumbnailConcurrency', type: 'number', descriptionKey: 'settings.image.thumbnailConcurrencyDesc' },
      { key: 'face_thumbnail_size', labelKey: 'settings.image.faceThumbSize', type: 'number', descriptionKey: 'settings.image.faceThumbSizeDesc' },
      { key: 'face_thumbnail_quality', labelKey: 'settings.image.faceThumbQuality', type: 'number', descriptionKey: 'settings.image.faceThumbQualityDesc' },
    ],
  },
  {
    id: 'db',
    titleKey: 'settings.group.db',
    settings: [
      { key: 'db_cache_size_mb', labelKey: 'settings.db.cacheSizeMb', type: 'number', descriptionKey: 'settings.db.cacheSizeMbDesc' },
      { key: 'db_synchronous', labelKey: 'settings.db.syncMode', type: 'select', descriptionKey: 'settings.db.syncModeDesc' },
    ],
  },
  {
    id: 'c1',
    titleKey: 'settings.group.c1',
    settings: [
      { key: 'c1_timeout_ms', labelKey: 'settings.c1.timeoutMs', type: 'number', descriptionKey: 'settings.c1.timeoutMsDesc' },
      { key: 'c1_retries', labelKey: 'settings.c1.retries', type: 'number', descriptionKey: 'settings.c1.retriesDesc' },
      { key: 'c1_reload_delay_ms', labelKey: 'settings.c1.reloadDelayMs', type: 'number', descriptionKey: 'settings.c1.reloadDelayMsDesc' },
    ],
  },
  {
    id: 'metadata',
    titleKey: 'settings.group.metadata',
    settings: [
      { key: 'metadata_write_mode', labelKey: 'settings.metadata.writeMode', type: 'select', descriptionKey: 'settings.metadata.writeModeDesc' },
      { key: 'metadata_write_debounce_ms', labelKey: 'settings.metadata.debounceMs', type: 'number', descriptionKey: 'settings.metadata.debounceMsDesc' },
      { key: 'capture_one_color_compatibility', labelKey: 'settings.metadata.colorCompat', type: 'select', descriptionKey: 'settings.metadata.colorCompatDesc' },
    ],
  },
]

function parseSelectOptions(description: string): { value: string; label: string }[] {
  return description.split(',').map((part) => {
    const [value, ...rest] = part.trim().split('=')
    return { value: value.trim(), label: rest.join('=').trim() }
  })
}

const FACE_SECTION_ID = 'face-analysis'
const MODELS_RUN_ID = 'models-run'
const ADVANCED_ID = 'advanced'
const LANGUAGE_ID = 'language'

// Fixed brand-style option labels (中文 / English, identical in both locale
// files): the options name the language itself, so localizing them would be
// self-referential and longer than the value they communicate.
const LANGUAGE_OPTIONS: Array<{ value: AppLocale; labelKey: TranslationKey }> = [
  { value: 'zh-CN', labelKey: 'settings.language.optionZh' },
  { value: 'en', labelKey: 'settings.language.optionEn' },
]

export default function SettingsPage() {
  const { t } = useTranslation()
  const settings = useSettingsStore((s) => s.settings)
  const loading = useSettingsStore((s) => s.loading)
  const dirty = useSettingsStore((s) => s.dirty)
  const mlStatus = useSettingsStore((s) => s.mlStatus)
  const mlStatusLoading = useSettingsStore((s) => s.mlStatusLoading)
  const load = useSettingsStore((s) => s.load)
  const loadMlStatus = useSettingsStore((s) => s.loadMlStatus)
  const setSetting = useSettingsStore((s) => s.setSetting)
  const resetToDefaults = useSettingsStore((s) => s.resetToDefaults)

  const [openSections, setOpenSections] = useState<Set<string>>(() => new Set(GROUPS.map((g) => g.id).concat(FACE_SECTION_ID, LANGUAGE_ID)))
  const [openSubSections, setOpenSubSections] = useState<Set<string>>(new Set())
  const [c1HealthOpen, setC1HealthOpen] = useState(true)
  const [language, setLanguage] = useState<AppLocale>(detectLanguage() as AppLocale)
  const languageSelectId = useId()
  const [downloadProgress, setDownloadProgress] = useState<{ filename: string; percent: number; phase?: string } | null>(null)
  const [downloadState, setDownloadState] = useState<'idle' | 'downloading' | 'done' | 'error'>('idle')
  const backendManual = mlStatus ? !mlStatus.isAuto : false
  const cpuCount = navigator.hardwareConcurrency || 4
  const maxConcurrency = Math.max(1, Math.min(8, cpuCount - 1))

  useEffect(() => {
    load()
    loadMlStatus()
    // The effective locale (settings override > --lang > system) lives in the
    // main process; reflect it here so the select shows what is really active.
    window.gather.getAppLocale()
      .then(({ language: effective }) => setLanguage(effective))
      .catch(() => {
        // Fall back to the navigator-based default (same failure path as main.tsx).
      })
  }, [load, loadMlStatus])

  useEffect(() => {
    if (downloadState !== 'downloading') return
    const unsub = window.gather.onModelDownloadProgress((data) => {
      const p = data as { filename: string; percent: number }
      setDownloadProgress(p)
    })
    return unsub
  }, [downloadState, loadMlStatus])

  const handleInstallModels = async () => {
    setDownloadState('downloading')
    setDownloadProgress(null)
    try {
      await window.gather.downloadDefaultModels()
      setDownloadState('done')
      await loadMlStatus()
      setTimeout(() => {
        setDownloadState('idle')
        setDownloadProgress(null)
      }, 2000)
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

  // One action, two effects (i18n P2 收尾): persist + rebuild the menu in the
  // main process, then apply the same locale here so UI copy switches
  // instantly. Menu and renderer copy are driven by the same value, so they
  // never disagree.
  const handleLanguageChange = async (value: AppLocale) => {
    try {
      await settingsApi.setLanguage(value)
      await initI18n(value)
      setLanguage(value)
    } catch (err) {
      console.error('Failed to switch language:', err)
    }
  }

  const getVal = (key: string, fallback: string) => {
    const v = settings[key]
    return v !== undefined && v !== '' ? v : fallback
  }

  if (loading) {
    return (
      <div className={styles.page}>
        <div className={styles.header}>
          <h1 className={styles.title}>{t('settings.title')}</h1>
        </div>
        <div className={styles.loading}>
          <Loading />
        </div>
      </div>
    )
  }

  const faceSection = (
    <div key={FACE_SECTION_ID} className={styles.section}>
      <button className={styles.sectionHeader} onClick={() => toggleSection(FACE_SECTION_ID)}>
        <span className={`${styles.chevron} ${openSections.has(FACE_SECTION_ID) ? styles.chevronOpen : ''}`}>
          &#9654;
        </span>
        {t('settings.faceAnalysis')}
      </button>

      {openSections.has(FACE_SECTION_ID) && (
        <div className={styles.sectionBody}>
          <div className={styles.subSectionLabel}>{t('settings.general')}</div>

          <div className={styles.settingRow}>
            <div className={styles.settingInfo}>
              <p className={styles.settingLabel}>{t('settings.detectConfidence')}</p>
              <p className={styles.settingDesc}>{t('settings.detectConfidenceDesc')}</p>
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
              <p className={styles.settingLabel}>{t('settings.clusterRadius')}</p>
              <p className={styles.settingDesc}>{t('settings.clusterRadiusDesc')}</p>
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
              <p className={styles.settingLabel}>{t('settings.minSamples')}</p>
              <p className={styles.settingDesc}>{t('settings.minSamplesDesc')}</p>
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

          {/* Models & runtime */}
          <div className={styles.settingDivider} />
          <button className={styles.subSectionHeader} onClick={() => toggleSubSection(MODELS_RUN_ID)}>
            <span className={`${styles.subChevron} ${openSubSections.has(MODELS_RUN_ID) ? styles.subChevronOpen : ''}`}>
              &#9654;
            </span>
            {t('settings.modelsRun')}
            <span className={styles.subSectionHint}>
              {mlStatusLoading ? t('settings.detecting') : mlStatus ? (mlStatus.detectorModel.exists && mlStatus.encoderModel.exists ? '✓' : '⚠') : ''}
            </span>
          </button>

          {openSubSections.has(MODELS_RUN_ID) && (
            <div className={styles.subSectionBody}>
              {mlStatusLoading ? (
                <div className={styles.statusLoading}>{t('settings.detectingStatus')}</div>
              ) : mlStatus ? (
                <>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{t('settings.detectorModel')}</p>
                    </div>
                    <div className={styles.modelStatus}>
                      <span className={mlStatus.detectorModel.exists ? styles.statusOk : styles.statusFail}>
                        {mlStatus.detectorModel.exists ? t('settings.ok') : t('settings.missing')}
                      </span>
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{t('settings.encoderModel')}</p>
                    </div>
                    <div className={styles.modelStatus}>
                      <span className={mlStatus.encoderModel.exists ? styles.statusOk : styles.statusFail}>
                        {mlStatus.encoderModel.exists ? t('settings.ok') : t('settings.missing')}
                      </span>
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{t('settings.detectorPath')}</p>
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
                        {t('settings.open')}
                      </button>
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{t('settings.encoderPath')}</p>
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
                        {t('settings.open')}
                      </button>
                    </div>
                  </div>

                  {(!mlStatus.detectorModel.exists || !mlStatus.encoderModel.exists) && (
                    <div className={styles.installBanner}>
                      <p>{t('settings.modelsMissing')}<br />{mlStatus.modelResourcesDir}</p>
                      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                        <button className={styles.installBtn} onClick={() => window.gather.openDirectory(mlStatus.modelResourcesDir)}>
                          {t('settings.openModelFolder')}
                        </button>
                        <button
                          className={styles.installBtn}
                          onClick={handleInstallModels}
                          disabled={downloadState === 'downloading'}
                        >
                          {downloadState === 'downloading' ? t('settings.downloading') : downloadState === 'error' ? t('settings.downloadFailed') : t('settings.downloadModels')}
                        </button>
                      </div>
                      {downloadProgress && (
                        <div style={{ marginTop: 8, fontSize: 12, color: 'var(--color-text-secondary)' }}>
                          {downloadProgress.phase
                            ? translatePhase(downloadProgress.phase)
                            : t('settings.modelsDownloadFilename', { filename: downloadProgress.filename, percent: Math.round(downloadProgress.percent) })}
                        </div>
                      )}
                    </div>
                  )}
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{t('settings.modelInfo')}</p>
                    </div>
                    <div className={styles.modelInfoText}>
                      {t('settings.modelInfoText', {
                        sec: mlStatus.modelInfo.secondaryDetectInputSize,
                        prim: mlStatus.modelInfo.detectInputSize,
                        preview: mlStatus.modelInfo.previewMaxDimension,
                        enc: mlStatus.modelInfo.encoderInputSize,
                        dim: mlStatus.modelInfo.embeddingDim,
                      })}
                    </div>
                  </div>
                  <div className={styles.settingRow}>
                    <div className={styles.settingInfo}>
                      <p className={styles.settingLabel}>{t('settings.backend')}</p>
                      <p className={styles.settingDesc}>
                        {mlStatus.isAuto
                          ? t('settings.autoBackend', { backend: mlStatus.autoBackendLabel })
                          : t('settings.manualBackend', { provider: mlStatus.provider })}
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
                        {backendManual ? t('settings.restoreAuto') : t('settings.manualSwitch')}
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
                <div className={styles.statusLoading}>{t('settings.noModelStatus')}</div>
              )}
            </div>
          )}

          {/* Advanced parameters */}
          <button className={styles.subSectionHeader} onClick={() => toggleSubSection(ADVANCED_ID)}>
            <span className={`${styles.subChevron} ${openSubSections.has(ADVANCED_ID) ? styles.subChevronOpen : ''}`}>
              &#9654;
            </span>
            {t('settings.advanced')}
          </button>

          {openSubSections.has(ADVANCED_ID) && (
            <div className={styles.subSectionBody}>
              <div className={styles.settingRow}>
                <div className={styles.settingInfo}>
                  <p className={styles.settingLabel}>{t('settings.nmsThreshold')}</p>
                  <p className={styles.settingDesc}>{t('settings.nmsThresholdDesc')}</p>
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
                  <p className={styles.settingLabel}>{t('settings.maxDetections')}</p>
                  <p className={styles.settingDesc}>{t('settings.maxDetectionsDesc')}</p>
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
                  <p className={styles.settingLabel}>{t('settings.onnxThreads')}</p>
                  <p className={styles.settingDesc}>{t('settings.onnxThreadsDesc')}</p>
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
        <h1 className={styles.title}>{t('settings.title')}</h1>
        {dirty && <span className={styles.dirtyHint}>{t('settings.dirtyHint')}</span>}
        <button className={styles.resetBtn} onClick={() => {
          if (window.confirm(t('settings.resetConfirm'))) {
            resetToDefaults()
          }
        }}>
          {t('settings.resetDefaults')}
        </button>
      </div>

      <div className={styles.section}>
        <button
          className={styles.sectionHeader}
          onClick={() => setC1HealthOpen((open) => !open)}
        >
          <span className={`${styles.chevron} ${c1HealthOpen ? styles.chevronOpen : ''}`}>
            &#9654;
          </span>
          {t('settings.c1Health')}
        </button>
        {c1HealthOpen && (
          <div className={styles.sectionBody}>
            <C1HealthPanel />
          </div>
        )}
      </div>

      <div className={styles.section}>
        <button
          className={styles.sectionHeader}
          onClick={() => toggleSection(LANGUAGE_ID)}
        >
          <span className={`${styles.chevron} ${openSections.has(LANGUAGE_ID) ? styles.chevronOpen : ''}`}>
            &#9654;
          </span>
          {t('settings.group.language')}
        </button>
        {openSections.has(LANGUAGE_ID) && (
          <div className={styles.sectionBody}>
            <div className={styles.settingRow}>
              <div className={styles.settingInfo}>
                <label className={styles.settingLabel} htmlFor={languageSelectId}>{t('settings.language.label')}</label>
                <p className={styles.settingDesc}>{t('settings.language.desc')}</p>
              </div>
              <div className={styles.settingInput}>
                <select
                  id={languageSelectId}
                  className={styles.select}
                  value={language}
                  onChange={(e) => handleLanguageChange(e.target.value as AppLocale)}
                >
                  {LANGUAGE_OPTIONS.map((option) => (
                    <option key={option.value} value={option.value}>{t(option.labelKey)}</option>
                  ))}
                </select>
              </div>
            </div>
          </div>
        )}
      </div>

      {faceSection}

      {GROUPS.map((group) => (
        <div key={group.id} className={styles.section}>
          <button
            className={styles.sectionHeader}
            onClick={() => toggleSection(group.id)}
          >
            <span className={`${styles.chevron} ${openSections.has(group.id) ? styles.chevronOpen : ''}`}>
              &#9654;
            </span>
            {t(group.titleKey)}
          </button>

          {openSections.has(group.id) && (
            <div className={styles.sectionBody}>
              {group.settings.map((setting) => {
                const currentValue = settings[setting.key] ?? ''
                const description = t(setting.descriptionKey)

                if (setting.type === 'select') {
                  const options = parseSelectOptions(description)
                  return (
                    <div key={setting.key} className={styles.settingRow}>
                      <div className={styles.settingInfo}>
                        <p className={styles.settingLabel}>{t(setting.labelKey)}</p>
                        <p className={styles.settingDesc}>{parseSelectOptions(description).map(o => o.label).join(t('list.separator'))}</p>
                      </div>
                      <div className={styles.settingInput}>
                        <select
                          className={styles.select}
                          value={currentValue}
                          onChange={(e) => setSetting(setting.key, e.target.value)}
                        >
                          <option value="" disabled>{t('settings.choose')}</option>
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
                      <p className={styles.settingLabel}>{t(setting.labelKey)}</p>
                      <p className={styles.settingDesc}>{t(setting.descriptionKey)}</p>
                    </div>
                    <div className={styles.settingInput}>
                      <input
                        className={styles.input}
                        type={setting.type === 'number' ? 'number' : 'text'}
                        value={currentValue}
                        min={setting.key === 'thumbnail_size' ? 256 : setting.key === 'thumbnail_concurrency' ? 1 : setting.key === 'memory_cache_max_size_mb' ? 32 : undefined}
                        max={setting.key === 'thumbnail_size' ? 2048 : setting.key === 'thumbnail_concurrency' ? maxConcurrency : setting.key === 'memory_cache_max_size_mb' ? 2048 : undefined}
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
