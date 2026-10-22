// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+Catalog.swift
// Cut 4 / 4c-2d：静态配置表——首屏/高级分组、并发上限、数字与标签文案、可清空键集合、
// 滑杆与分组字段定义（原 SettingsView.swift 265-276、759-994 行）。纯搬移：
// 键名/范围/中文标签逐字不变（SettingsCatalogTests 守住键集合）。
import Foundation
import GatherProtocol

extension SettingsViewModel {

    /// 首屏日常分组（F11）：图片处理、Capture One 集成、元数据、缓存。
    /// 顺序即首屏顺序——日常设置在前，实现细节在后。
    public static var primaryGroups: [SettingGroup] {
        let primaryIds = ["image", "c1", "metadata", "cache"]
        return primaryIds.compactMap { id in settingGroups.first { $0.id == id } }
    }

    /// 高级分组（F11）：数据库、人脸模型参数——折叠在「高级」里，默认不占首屏。
    public static var advancedGroups: [SettingGroup] {
        let advancedIds = ["face", "db"]
        return advancedIds.compactMap { id in settingGroups.first { $0.id == id } }
    }
    // MARK: - 静态配置表（对齐 TS GROUPS / 滑杆段）

    /// TS: Math.max(1, Math.min(8, cpuCount - 1))。
    public static var maxConcurrency: Double {
        let cores = ProcessInfo.processInfo.processorCount
        return Double(max(1, min(8, cores - 1)))
    }

    /// 数值文案（设置校验提示里的 min/max）：整数不带小数，其余保留两位。
    /// Cut 4 / 4b-2g：模板经传入的 L10n 渲染（`%.2f` 本身保留——这是机器值，
    /// 不做本地化数字样式；zh/en 小数点一致，输出逐字不变）。
    public static func numberText(_ value: Double, with l10n: L10n) -> String {
        value == value.rounded() ? String(Int(value)) : l10n.format("%.2f", value)
    }

    /// 设置键 → 界面标签（滑杆或分组字段里找到就用 zhLabel；否则退回键名）。
    /// 用于保存提示，避免把内部键暴露给用户。
    /// Cut 4 / 4b-2g：动态 key 由调用方传入的 L10n 解析（VM 不读进程全局语言）。
    public static func label(for key: String, with l10n: L10n) -> String {
        if let slider = (generalSliders + advancedSliders).first(where: { $0.key == key }) {
            return l10n(slider.zhLabel)
        }
        for group in settingGroups {
            if let field = group.fields.first(where: { $0.key == key }) {
                return l10n(field.zhLabel)
            }
        }
        return key
    }

    /// 可清空键 = core 默认值表中 value 为空串的键。
    ///
    /// Cut 3 / 3b-3（E-19 #2）：GatherUI 不能 import GatherApplication，无法直接读
    /// SettingsService.getDefaults()；这里保留同一份键集合（值快照自
    /// GatherApplication/Services/SettingsService.swift 的默认值表）。新增"默认空"
    /// 设置键时需同步本表（SettingsCatalogTests 守住键集合）。
    public static let clearableSettingKeys: Set<String> = [
        "face_embedding_model_path",
        "face_embedding_model_version",
        "model_download_url",
        "face_thumbnail_dir",
        "disk_cache_dir",
        "ui_language",
    ]

    /// 该键在 core 默认表里是否为空串（决定"清空输入框"是否为合法操作）。
    public static func defaultValueIsEmpty(_ key: String) -> Bool {
        clearableSettingKeys.contains(key)
    }

    /// 人脸分析常规参数（TS index.tsx L227-286）。
    public static let generalSliders: [SliderSetting] = [
        SliderSetting(
            key: "detect_confidence", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.5,
            zhLabel: "检测敏感度",
            zhDesc: "低于此置信度的人脸将被忽略"
        ),
        SliderSetting(
            key: "default_eps", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.65,
            zhLabel: "同一人相似度下限",
            zhDesc: "仅相似度不低于该值的人脸才归为同一人；值越大越严格"
        ),
        SliderSetting(
            key: "default_min_samples", min: 1, max: 20, step: 1, isInteger: true, defaultValue: 2,
            zhLabel: "最小样本数",
            zhDesc: "一个人至少出现 N 张照片才形成聚类"
        ),
    ]

    /// 原生分析实际使用的高级参数；旧 ONNX/NMS 设置仅保留存储兼容。
    public static let advancedSliders: [SliderSetting] = [
        SliderSetting(
            key: "max_detections", min: 1, max: 500, step: 1, isInteger: true, defaultValue: 100,
            zhLabel: "最大检测数",
            zhDesc: "单张图片最多检测的人脸数"
        ),
        SliderSetting(
            key: "face_decode_concurrency", min: 1, max: 8, step: 1, isInteger: true, defaultValue: 4,
            zhLabel: "照片解码并发数", zhDesc: "同时准备的照片数；内存紧张时调低"
        ),
        // 原生质量与匹配参数。
        SliderSetting(
            key: "face_core_quality", min: 0, max: 1, step: 0.05, isInteger: false, defaultValue: 0.35,
            zhLabel: "核心点质量门槛",
            zhDesc: "质量低于此值的人脸不能带动聚类（只可能被并入），0 = 不设限；调高可减少模糊/侧脸造成的误聚"
        ),
        SliderSetting(
            key: "face_core_retry_min_samples", min: 1, max: 10, step: 1, isInteger: true, defaultValue: 2,
            zhLabel: "二遍最小样本数",
            zhDesc: "首遍漏掉的小簇在二遍中恢复；小于 2 视为关闭"
        ),
        SliderSetting(
            key: "face_match_margin", min: 0, max: 0.2, step: 0.005, isInteger: false, defaultValue: 0.01,
            zhLabel: "歧义判定间隔",
            zhDesc: "最相似与次相似人物的差距小于此值时不自动绑定身份，留给人工确认；0 = 总是绑定最相似者"
        ),
    ]

    /// 分组设置（TS index.tsx L25-74；min/max 抄 input 约束 + 描述文案约束）。
    public static let settingGroups: [SettingGroup] = [
        SettingGroup(id: "cache", titleZh: "缓存", fields: [
            SettingField(
                key: "memory_cache_size", type: .number(min: 1, max: nil),
                zhLabel: "内存缓存条目数",
                zhDesc: "内存中缓存的缩略图最大数量"
            ),
            SettingField(
                key: "memory_cache_max_size_mb", type: .number(min: 32, max: 2048),
                zhLabel: "内存缓存上限 (MB)",
                zhDesc: "缩略图和预览内存缓存的最大空间，防止高分辨率图片占满内存"
            ),
            SettingField(
                key: "disk_cache_dir", type: .text,
                zhLabel: "磁盘缓存目录",
                zhDesc: "磁盘缓存存储路径（留空使用默认）"
            ),
            SettingField(
                key: "disk_cache_max_size_gb", type: .number(min: 0, max: nil),
                zhLabel: "磁盘缓存上限 (GB)",
                zhDesc: "磁盘缓存占用硬盘的最大空间"
            ),
            SettingField(
                key: "disk_cache_eviction_policy", type: .select([
                    SelectOption(value: "lru", labelZh: "LRU（最近最少使用）"),
                    SelectOption(value: "fifo", labelZh: "FIFO（先进先出）"),
                    SelectOption(value: "lfu", labelZh: "LFU（最不经常使用）"),
                ]),
                zhLabel: "淘汰策略",
                zhDesc: "lru=LRU（最近最少使用）, fifo=FIFO（先进先出）, lfu=LFU（最不经常使用）"
            ),
        ]),
        SettingGroup(id: "image", titleZh: "图片处理", fields: [
            SettingField(
                key: "thumbnail_size", type: .number(min: 256, max: 2048),
                zhLabel: "缩略图尺寸",
                zhDesc: "画廊缓存分辨率（建议 1024；内部按 256/1024/2048 三级复用）"
            ),
            SettingField(
                key: "thumbnail_quality", type: .number(min: 0, max: 100),
                zhLabel: "缩略图质量",
                zhDesc: "缩略图的 JPEG 压缩质量 (0-100)"
            ),
            SettingField(
                key: "thumbnail_concurrency", type: .number(min: 1, max: maxConcurrency),
                zhLabel: "缩略图生成并发数",
                zhDesc: "同时生成缩略图的任务数（RAW 建议 2-4，最大 8）"
            ),
            SettingField(
                key: "face_thumbnail_size", type: .number(min: 1, max: nil),
                zhLabel: "人脸缩略图尺寸",
                zhDesc: "人脸缩略图的宽高像素值"
            ),
            SettingField(
                key: "face_thumbnail_quality", type: .number(min: 0, max: 100),
                zhLabel: "人脸缩略图质量",
                zhDesc: "人脸缩略图的 JPEG 压缩质量 (0-100)"
            ),
        ]),
        SettingGroup(id: "db", titleZh: "数据库", fields: [
            SettingField(
                key: "db_cache_size_mb", type: .number(min: 1, max: 1024),
                zhLabel: "缓存大小 (MB)",
                zhDesc: "SQLite 数据库的页面缓存大小"
            ),
            SettingField(
                key: "db_synchronous", type: .select([
                    SelectOption(value: "off", labelZh: "OFF（关闭）"),
                    SelectOption(value: "normal", labelZh: "NORMAL（正常）"),
                    SelectOption(value: "full", labelZh: "FULL（完整）"),
                ]),
                zhLabel: "同步模式",
                zhDesc: "off=OFF（关闭）, normal=NORMAL（正常）, full=FULL（完整）"
            ),
        ]),
        SettingGroup(id: "c1", titleZh: "Capture One 集成", fields: [
            SettingField(
                key: "c1_timeout_ms", type: .number(min: 1, max: nil),
                zhLabel: "超时时间 (ms)",
                zhDesc: "与 Capture One 通信的超时毫秒数"
            ),
            SettingField(
                key: "c1_retries", type: .number(min: 0, max: nil),
                zhLabel: "重试次数",
                zhDesc: "与 Capture One 通信的最大重试次数"
            ),
            SettingField(
                key: "c1_reload_delay_ms", type: .number(min: 0, max: nil),
                zhLabel: "重载延迟 (ms)",
                zhDesc: "重载元数据后的等待延迟毫秒数"
            ),
        ]),
        SettingGroup(id: "metadata", titleZh: "元数据", fields: [
            SettingField(
                key: "metadata_write_mode", type: .select([
                    SelectOption(value: "auto", labelZh: "自动（RAW侧边栏，成品格式内嵌）"),
                    SelectOption(value: "sidecar", labelZh: "XMP Sidecar"),
                    SelectOption(value: "embedded", labelZh: "Embedded"),
                ]),
                zhLabel: "写入方式",
                zhDesc: "auto=自动（RAW侧边栏，成品格式内嵌）, sidecar=XMP Sidecar, embedded=Embedded"
            ),
            SettingField(
                key: "metadata_write_debounce_ms", type: .number(min: 1, max: nil),
                zhLabel: "后台写入防抖 (ms)",
                zhDesc: "连续评级或改色后等待多久合并写入，建议 300-800"
            ),
            SettingField(
                key: "capture_one_color_compatibility", type: .select([
                    SelectOption(value: "label_and_urgency", labelZh: "Label + Urgency（推荐，兼容更多版本）"),
                    SelectOption(value: "label_only", labelZh: "仅标准 xmp:Label"),
                ]),
                zhLabel: "Capture One 颜色兼容",
                zhDesc: "label_and_urgency=Label + Urgency（推荐，兼容更多版本）, label_only=仅标准 xmp:Label"
            ),
        ]),
        SettingGroup(id: "face", titleZh: "人脸模型", fields: [
            SettingField(
                key: "face_embedding_model_path", type: .text,
                zhLabel: "专用人脸模型路径",
                zhDesc: "留空使用应用内置 SFace 身份模型；也可选择 112×112 图像输入的 CoreML 模型。换模型后需要全量重新分析，已有人工身份与纠错记录会保留。"
            ),
            SettingField(
                key: "face_embedding_model_version", type: .text,
                zhLabel: "模型版本标签",
                zhDesc: "仅用于记录与追溯（写入人脸观测，便于区分换模型前后的数据）；换模型时建议同时更新，例如 arcface-r100-w600k"
            ),
            SettingField(
                key: "face_incremental_clustering", type: .select([
                    SelectOption(value: "1", labelZh: "开（推荐，保留已绑定身份）"),
                    SelectOption(value: "0", labelZh: "关（每次全量重聚类）"),
                ]),
                zhLabel: "增量聚类",
                zhDesc: "开=优先处理新增照片；模型或人工约束变化时会重新聚类。关=每次重新聚类。两种方式都会保留人工身份与纠错记录。"
            ),
        ]),
    ]
}
