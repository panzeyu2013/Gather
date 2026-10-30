// desktop/native/gather-core/Sources/GatherApplication/Services/SettingsService.swift
// TS 源: desktop/src/main/services/settings/settings.service.ts（Phase 3.6 移植）
//
// 行为契约（与 TS 逐条对应）：
//   - 内存 Map 缓存：构造时 loadCache() 全量灌入，之后只读缓存不回库
//   - set：未知 key 抛 "Unknown setting key: <key>"（KNOWN_SETTING_KEYS 由
//     默认值表键派生，新增默认键自动进白名单）
//   - getNumber：parseFloat 语义（NaN 回退默认值）
//   - getAll：默认值表打底，缓存逐项覆盖（全部 String(value) 化）
//   - reset：repo.batchUpsert(默认值全量) + 缓存全量重置
// 与 TS 的差异：
//   - thumbnail_concurrency 默认值用 ProcessInfo.processorCount - 1（等价
//     os.cpus().length - 1，clamp 1..4）；TS 唯一 Node 依赖点
//   - lazy_checksum 默认 'true'（字符串，非布尔——与 TS 一致）
import Foundation
import GatherPersistence
import GatherProtocol

/// 并发依据：cache 的读写全部在 NSLock 临界区内；repo 是构造后不可变的 DB 仓储，
/// 由 DBConnection 串行化。标注集中在状态所有者，LiveSettingsAPI 等调用方因此
/// 可以保持普通 Sendable，不再各自 @unchecked。
public final class SettingsService: @unchecked Sendable {
    /// TS: getDefaults() —— 40 键默认值表。
    public static func getDefaults() -> [String: String] {
        [
            "detector_model_path": "models/face_detector.onnx",
            "encoder_model_path": "models/face_encoder.onnx",
            "detect_confidence": "0.5",
            "detect_input_size": "640",
            "detect_secondary_input_size": "128",
            "face_preview_max_dimension": "2048",
            "encoder_input_size": "112",
            "embedding_dim": "128",
            "face_compute_units": "auto",

            "default_eps": "0.65",
            "default_min_samples": "2",

            // 原生扩展（TS 无对应键；算法对标改造，见 ADR-029）：
            // · face_core_quality：核心点质量门槛（0 = 不设限）
            // · face_core_retry_min_samples：二遍核心点 minPts（<2 视为关闭）
            // · face_match_margin：冠军与人物级亚军的相似度差下限（不足则不写建议）
            "face_core_quality": "0.35",
            "face_core_retry_min_samples": "2",
            "face_match_margin": "0.01",
            // P0 / F0：复核队列阈值（可调；默认值见 f0 设计）
            "face_review_cohesion_floor": "0.35",
            "face_review_relative_mad": "2.5",
            "face_review_min_quality": "0.35",
            "face_review_face_size_min": "48",
            // · face_incremental_clustering：增量聚类开关（"1" = 开[推荐]；其余 = 关）。
            //   开启后 analyze 保留已有簇 id / matched_person_id / role_bindings，只
            //   追加新增人脸；首次分析、签名变化、recluster 命令仍走全量。
            "face_incremental_clustering": "1",
            // 专用人脸嵌入模型（ADR-029 决策 1 的模型层）：
            // 路径非空必须可加载（.mlmodel/.mlmodelc，112×112 图像输入），失败即报错，
            // 不静默回退到内置 Vision 特征——混用两套向量空间会让阈值全部失去意义。
            "face_embedding_model_path": "",
            "face_embedding_model_version": "",

            "nms_threshold": "0.4",
            "max_detections": "100",
            "onnx_threads": "4",

            "default_threshold": "10",
            "default_min_group_size": "2",

            "model_download_url": "",

            "thumbnail_size": "1024",
            "thumbnail_quality": "80",

            "disk_cache_dir": "",
            "face_decode_concurrency": "4",
            "face_inference_parallel_workers": "1",

            "db_cache_size_mb": "64",
            // 与宿主 DB 打开默认值保持同步（TS 注释：main/index.ts 的
            // settings.get('db_synchronous', 'normal')）。
            "db_synchronous": "normal",

            "metadata_write_mode": "auto",

            "ui_language": "",
            "lazy_checksum": "true",

            // P0 / G0：网格默认排序与密度（窗口内可临时覆盖）
            "grid_default_sort": "import",
            "grid_density": "m",

            // P0 / T0：技术质量建议（Beta）
            "triage_enabled": "0",
            "output.recipes": "",
            "output.deliveryRoot": "",
            "triage_model_review": "1",
            "triage_auto_apply": "0",
            "triage_auto_generate": "0",
            "triage_policy": "triage-v2",
            "triage_keep_confidence_min": "0.60",
            "triage_reject_confidence_min": "0.75",
            "triage_min_executable_confidence": "0.55",

            // P1 / B2：元数据模板（单键 JSON 数组）
            "metadata.templates": "[]",
            "metadata.templates.corrupt": "",
            "metadata.applyBatches": "[]",
            // 解析失败时的原文留证（见 MetadataApplyBatchStore.preserveCorruptPayload）
            "metadata.applyBatches.corrupt": "",
            // P1 / D：FSEvents 各会话的 lastEventID（JSON 对象，单键避免动态 key）
            "watch.lastEventIDs": "{}",

            // B0：备份 / 诊断
            "backup_dir": "",
            "backup_retention": "5",
            "backup_auto": "off",
            "diagnostics_include_paths": "0",

            // P1 下一波：元数据生命周期 / 写盘 / 关键词 / 检索 / 校样 / 语义
            "metadata_backup_retention_days": "7",
            "metadata_sync_auto_confirm": "1",
            "metadata_sync_auto_finalize": "0",
            "embedded_fast_path": "1",
            "keyword_dc_style": "leaf",
            "keyword_thesaurus_search": "1",
            "gallery_saved_search_limit": "50",
            "proof_feedback_apply_rating": "0",
            "c1_auto_reload": "1",
            "triage_calibration_min_samples": "50",
            "focus_mask_threshold": "0.55",
            "semantic_index_enabled": "0",
        ]
    }

    /// TS: KNOWN_SETTING_KEYS = new Set(Object.keys(getDefaults()))。
    public static var knownSettingKeys: Set<String> {
        Set(getDefaults().keys)
    }

    /// P1-5：reset 必须保留的“用户内容”键。
    ///
    /// 这些不是偏好设置，而是用户产物/索引：元数据模板、批次撤销历史、交付配方、
    /// 交付目录、备份目录、损坏留证。旧 reset 把它们一起写回默认值，导致
    /// 一次“恢复默认”不可逆地清空模板/配方/历史。语言仍是偏好，reset 会重置，
    /// 但 UI 必须同步 LanguageStore（见 SettingsViewModel.applyResetSettings）。
    public static let userContentKeysPreservedOnReset: Set<String> = [
        "metadata.templates",
        "metadata.applyBatches",
        "metadata.templates.corrupt",
        "metadata.applyBatches.corrupt",
        "output.recipes",
        "output.deliveryRoot",
        "backup_dir",
    ]

    /// P1-1：设置仓储走 Persistence 端口（any SettingsRepository），具体 SQLite
    /// Repo 只在组合根构造；测试可用 fake 替换。
    private let repo: any SettingsRepository
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init(repo: any SettingsRepository) {
        self.repo = repo
        loadCache()
    }

    private func loadCache() {
        if let all = try? repo.getAll() {
            for row in all {
                cache[row.key] = row.value
            }
        }
    }

    // MARK: API

    /// TS: get(key, defaultValue?) —— 缓存未命中 → defaultValue ?? ''。
    public func get(_ key: String, defaultValue: String? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        return cache[key] ?? defaultValue ?? ""
    }

    /// TS: getNumber(key, defaultValue) —— parseFloat，NaN 回退默认值。
    public func getNumber(_ key: String, defaultValue: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let raw = cache[key] else { return defaultValue }
        let parsed = Double(raw)
        guard let parsed else { return defaultValue }
        // 问题 6（第三轮审查）：inf/-inf 也要回落默认值——Swift 把非有限 Double
        // 转 Int 会直接 trap（导入/脚本写入的异常值会让页面崩溃）。
        return parsed.isFinite ? parsed : defaultValue
    }

    /// TS: set(key, value) —— 未知 key 抛错；repo.upsert + cache 双写。
    public func set(_ key: String, value: String) throws {
        guard Self.knownSettingKeys.contains(key) else {
            throw SettingsError.unknownKey(key)
        }
        try repo.upsert(key: key, value: value)
        lock.lock(); defer { lock.unlock() }
        cache[key] = value
    }

    /// TS: getAll() —— 默认值打底 + 缓存覆盖。
    public func getAll() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var result = Self.getDefaults()
        for (key, value) in cache {
            result[key] = value
        }
        return result
    }

    /// 运行时清理键：不属于用户可见偏好，reset 时总是回到默认。
    public static let runtimeKeysResetAlways: Set<String> = [
        "watch.lastEventIDs",
    ]

    public static let languageKey = "ui_language"

    /// reset 的显式 scope 分类（穷尽性由 SettingsServiceTests 守护）。
    enum ResetScope: Equatable {
        case preference
        case userContent
        case runtime
        case language
    }

    /// 显式偏好键白名单：新增键若不登记到任一 scope，resetScope 返回 nil，
    /// 默认 reset 会保留它（fail-closed），测试也会红。
    static let preferenceKeys: Set<String> = [
        "backup_auto",
        "backup_retention",
        "db_cache_size_mb",
        "db_synchronous",
        "default_eps",
        "default_min_group_size",
        "default_min_samples",
        "default_threshold",
        "detect_confidence",
        "detect_input_size",
        "detect_secondary_input_size",
        "detector_model_path",
        "diagnostics_include_paths",
        "disk_cache_dir",
        "embedding_dim",
        "encoder_input_size",
        "encoder_model_path",
        "face_compute_units",
        "face_core_quality",
        "face_core_retry_min_samples",
        "face_decode_concurrency",
        "face_embedding_model_path",
        "face_embedding_model_version",
        "face_incremental_clustering",
        "face_inference_parallel_workers",
        "face_match_margin",
        "face_preview_max_dimension",
        "face_review_cohesion_floor",
        "face_review_face_size_min",
        "face_review_min_quality",
        "face_review_relative_mad",
        "grid_default_sort",
        "grid_density",
        "lazy_checksum",
        "max_detections",
        "metadata_write_mode",
        "model_download_url",
        "nms_threshold",
        "onnx_threads",
        "thumbnail_quality",
        "thumbnail_size",
        "triage_auto_apply",
        "triage_auto_generate",
        "triage_enabled",
        "triage_keep_confidence_min",
        "triage_min_executable_confidence",
        "triage_model_review",
        "triage_policy",
        "triage_reject_confidence_min",
        "metadata_backup_retention_days",
        "metadata_sync_auto_confirm",
        "metadata_sync_auto_finalize",
        "embedded_fast_path",
        "keyword_dc_style",
        "keyword_thesaurus_search",
        "gallery_saved_search_limit",
        "proof_feedback_apply_rating",
        "c1_auto_reload",
        "triage_calibration_min_samples",
        "focus_mask_threshold",
        "semantic_index_enabled",
    ]

    /// 每个 known key 恰好落到一个 scope；未知键返回 nil（不静默按偏好处理）。
    static func resetScope(for key: String) -> ResetScope? {
        if userContentKeysPreservedOnReset.contains(key) { return .userContent }
        if key == languageKey { return .language }
        if runtimeKeysResetAlways.contains(key) { return .runtime }
        if preferenceKeys.contains(key) { return .preference }
        return nil
    }

    /// P1-5：影响面预览；只读当前值，不读 secret。
    public func previewReset() -> SettingsResetImpact {
        let current = getAll()
        let userContent = Self.userContentKeysPreservedOnReset
        let preferenceCount = Self.getDefaults().keys.filter {
            !userContent.contains($0)
                && $0 != Self.languageKey
                && !Self.runtimeKeysResetAlways.contains($0)
        }.count
        return SettingsResetImpact(
            preferenceCount: preferenceCount,
            templateCount: Self.jsonArrayCount(current["metadata.templates"]),
            batchCount: Self.jsonArrayCount(current["metadata.applyBatches"]),
            recipeCount: Self.jsonArrayCount(current["output.recipes"])
        )
    }

    /// TS: reset() —— 旧入口，等价于 preferences + language（保留用户内容）。
    public func reset() throws {
        _ = try reset(input: SettingsResetInput(
            resetPreferences: true, resetUserContent: false, resetLanguage: true))
    }

    /// P1-5：分级 reset。用户内容/语言默认保留，必须显式勾选；
    /// 运行时键（watch cursor）始终清理；整批写入仍走一次 batchUpsert。
    @discardableResult
    public func reset(input: SettingsResetInput) throws -> SettingsResetResult {
        let defaults = Self.getDefaults()
        var resetEntries: [(key: String, value: String)] = []
        var resetKeys: [String] = []
        var preservedKeys: [String] = []
        for (key, defaultValue) in defaults {
            guard let scope = Self.resetScope(for: key) else {
                // knownSettingKeys 与 defaults 同源；走到这里说明分类表漏项，
                // fail-closed 保留现值而不是静默按偏好清掉。
                preservedKeys.append(key)
                continue
            }
            let selected: Bool
            switch scope {
            case .userContent: selected = input.resetUserContent
            case .language: selected = input.resetLanguage
            case .runtime: selected = true
            case .preference: selected = input.resetPreferences
            }
            if selected {
                resetEntries.append((key, defaultValue))
                resetKeys.append(key)
            } else {
                preservedKeys.append(key)
            }
        }
        // 只写被重置的键：整表回写会把“读快照 → 写库”之间发生的并发写（配方持久化、
        // 切语言）覆盖回旧值，等于把用户刚做的修改丢掉。
        try repo.batchUpsert(entries: resetEntries)
        // 只把本次真正写入的键并入缓存。整表替换会把 batchUpsert 与这里之间
        // 发生的并发 set（配方持久化/切语言）在 DB 已生效的值盖回旧快照。
        lock.lock()
        for (key, value) in resetEntries {
            cache[key] = value
        }
        lock.unlock()
        let values = getAll()
        return SettingsResetResult(
            values: values,
            resetKeys: resetKeys.sorted(),
            preservedKeys: preservedKeys.sorted()
        )
    }

    private static func jsonArrayCount(_ raw: String?) -> Int {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [Any] else {
            return 0
        }
        return array.count
    }
}

/// 未知设置键错误（TS: Error(`Unknown setting key: ${key}`) 消息逐字一致，
/// 宿主桥接层按 description 序列化）。
public enum SettingsError: Error, CustomStringConvertible {
    case unknownKey(String)

    public var description: String {
        switch self {
        case .unknownKey(let key): return "Unknown setting key: \(key)"
        }
    }
}
