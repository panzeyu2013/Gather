import React, { useEffect, useState } from 'react'
import { useSettingsStore } from '../../stores/settingsStore'
import Loading from '../../components/Loading/Loading'
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
      { key: 'preview_max_dimension', label: '预览图最大尺寸', type: 'number', description: '预览图的最大宽/高像素值' },
      { key: 'preview_quality', label: '预览图质量', type: 'number', description: '预览图的 JPEG 压缩质量 (0-100)' },
      { key: 'thumbnail_size', label: '缩略图尺寸', type: 'number', description: '缩略图的宽高像素值' },
      { key: 'thumbnail_quality', label: '缩略图质量', type: 'number', description: '缩略图的 JPEG 压缩质量 (0-100)' },
      { key: 'face_thumbnail_size', label: '人脸缩略图尺寸', type: 'number', description: '人脸缩略图的宽高像素值' },
      { key: 'face_thumbnail_quality', label: '人脸缩略图质量', type: 'number', description: '人脸缩略图的 JPEG 压缩质量 (0-100)' },
    ],
  },
  {
    title: 'ML 模型',
    settings: [
      { key: 'detector_model_path', label: '检测模型路径', type: 'text', description: '人脸检测 ONNX 模型文件路径' },
      { key: 'encoder_model_path', label: '编码模型路径', type: 'text', description: '人脸编码 ONNX 模型文件路径' },
      { key: 'onnx_provider', label: 'ONNX 运行后端', type: 'select', description: 'cpu=CPU, CoreMLExecutionProvider=CoreML, DmlExecutionProvider=DirectML' },
      { key: 'detect_confidence', label: '检测置信度', type: 'number', description: '人脸检测的最低置信度 (0-1)' },
      { key: 'detect_input_size', label: '检测输入尺寸', type: 'number', description: '检测模型的输入图像尺寸' },
      { key: 'encoder_input_size', label: '编码输入尺寸', type: 'number', description: '编码模型的输入图像尺寸' },
      { key: 'embedding_dim', label: '特征向量维度', type: 'number', description: '人脸特征向量的维度' },
    ],
  },
  {
    title: '人脸聚类',
    settings: [
      { key: 'default_eps', label: '聚类半径 (eps)', type: 'number', description: 'DBSCAN 聚类的最大邻域距离' },
      { key: 'default_min_samples', label: '最小样本数', type: 'number', description: 'DBSCAN 聚类的最小样本数' },
    ],
  },
  {
    title: '相似度聚类',
    settings: [
      { key: 'default_threshold', label: '相似度阈值', type: 'number', description: '图像相似度分组的阈值' },
      { key: 'default_min_group_size', label: '最小分组大小', type: 'number', description: '相似度分组的最小图像数量' },
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
  const load = useSettingsStore((s) => s.load)
  const setSetting = useSettingsStore((s) => s.setSetting)
  const resetToDefaults = useSettingsStore((s) => s.resetToDefaults)

  const [openSections, setOpenSections] = useState<Set<string>>(() => new Set(GROUPS.map((g) => g.title)))

  useEffect(() => {
    load()
  }, [load])

  const toggleSection = (title: string) => {
    setOpenSections((prev) => {
      const next = new Set(prev)
      if (next.has(title)) {
        next.delete(title)
      } else {
        next.add(title)
      }
      return next
    })
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

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>设置</h1>
        <button className={styles.resetBtn} onClick={resetToDefaults}>
          重置为默认值
        </button>
      </div>

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
