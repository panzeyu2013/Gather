// desktop/native/gather-core/Sources/GatherCore/Services/SettingsService.swift
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

public final class SettingsService {
    /// TS: getDefaults() —— 40 键默认值表（单一来源：SettingsAPI.defaults）。
    public static func getDefaults() -> [String: String] { SettingsAPI.defaults }

    /// TS: Math.max(1, Math.min(4, os.cpus().length - 1))。
    public static var thumbnailConcurrencyDefault: Int { SettingsAPI.thumbnailConcurrencyDefault }

    /// TS: KNOWN_SETTING_KEYS = new Set(Object.keys(getDefaults()))。
    public static var knownSettingKeys: Set<String> { SettingsAPI.knownSettingKeys }

    private let repo: SettingsRepo
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init(repo: SettingsRepo) {
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
        return parsed.isNaN ? defaultValue : parsed
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

    /// TS: reset() —— batchUpsert 默认值全量 + 缓存重置。
    public func reset() throws {
        let defaults = Self.getDefaults()
        try repo.batchUpsert(entries: defaults.map { (key: $0.key, value: $0.value) })
        lock.lock(); defer { lock.unlock() }
        cache = defaults
    }
}
