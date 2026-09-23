// API/GatherAPI.swift
// R5 基座：组合根（AppContainer）+ 类型化 async API（GatherAPI）。
// feature 只依赖 GatherAPI，不接触 Store/SQL；本文件首批落地 settings 与 sessions，
// 其余命名空间随各 feature 重写逐个并入。
import Foundation

/// 应用组合根：拥有唯一 SQLiteDatabase 与各 Store（取代 DBConnection + 服务手拼）。
public struct AppContainer: Sendable {
    public let database: SQLiteDatabase
    public let settings: any SettingsStore
    public let sessions: any SessionStore
    public let templates: any TemplateStore
    public let albums: any SmartAlbumStore

    public init(database: SQLiteDatabase) {
        self.database = database
        self.settings = SQLiteSettingsStore(database: database)
        self.sessions = SQLiteSessionStore(database: database)
        self.templates = SQLiteTemplateStore(database: database)
        self.albums = SQLiteSmartAlbumStore(database: database)
    }

    /// 打开（必要时迁移到当前版本）指定路径的库。
    public static func open(
        path: String,
        configuration: SQLiteDatabase.Configuration = SQLiteDatabase.Configuration()
    ) async throws -> AppContainer {
        let database = try SQLiteDatabase(path: path, configuration: configuration)
        try await StoreMigrator().migrate(database)
        return AppContainer(database: database)
    }
}

/// 类型化 API 门面：feature 的唯一入口。
public struct GatherAPI: Sendable {
    public let container: AppContainer
    public let settings: SettingsAPI
    public let sessions: SessionsAPI
    public let templates: TemplatesAPI
    public let albums: AlbumsAPI

    public init(container: AppContainer) {
        self.container = container
        self.settings = SettingsAPI(store: container.settings)
        self.sessions = SessionsAPI(store: container.sessions)
        self.templates = TemplatesAPI(templates: container.templates, sessions: container.sessions)
        self.albums = AlbumsAPI(store: container.albums)
    }

    public static func open(path: String) async throws -> GatherAPI {
        GatherAPI(container: try await AppContainer.open(path: path))
    }
}

/// 设置命名空间：默认值表 + 白名单 + 内存缓存语义（取代 SettingsService）。
public actor SettingsAPI {
    /// TS: getDefaults() —— 40 键默认值表（唯一来源）。
    public static let defaults: [String: String] = [
        "detector_model_path": "models/face_detector.onnx",
        "encoder_model_path": "models/face_encoder.onnx",
        "onnx_provider": "auto",
        "detect_confidence": "0.5",
        "detect_input_size": "640",
        "detect_secondary_input_size": "128",
        "face_preview_max_dimension": "2048",
        "encoder_input_size": "112",
        "embedding_dim": "512",

        "default_eps": "0.6",
        "default_min_samples": "2",

        "nms_threshold": "0.4",
        "max_detections": "100",
        "onnx_threads": "4",

        "default_threshold": "10",
        "default_min_group_size": "2",

        "model_download_url": "",

        "thumbnail_size": "1024",
        "thumbnail_quality": "80",
        "face_thumbnail_size": "320",
        "face_thumbnail_quality": "70",
        "face_thumbnail_dir": "",

        "memory_cache_size": "10000",
        "memory_cache_max_size_mb": "192",
        "disk_cache_dir": "",
        "disk_cache_max_size_gb": "1",
        "disk_cache_eviction_policy": "lru",
        "thumbnail_concurrency": "\(SettingsAPI.thumbnailConcurrencyDefault)",
        "face_decode_concurrency": "4",
        "face_inference_parallel_workers": "1",

        "db_cache_size_mb": "64",
        "db_synchronous": "normal",

        "c1_timeout_ms": "15000",
        "c1_retries": "3",
        "c1_reload_delay_ms": "500",

        "metadata_write_mode": "sidecar",
        "metadata_write_debounce_ms": "500",
        "capture_one_color_compatibility": "label_and_urgency",

        "ui_language": "",
        "lazy_checksum": "true",
    ]

    /// TS: Math.max(1, Math.min(4, os.cpus().length - 1))。
    public static var thumbnailConcurrencyDefault: Int {
        let cores = ProcessInfo.processInfo.processorCount
        return max(1, min(4, cores - 1))
    }

    /// TS: KNOWN_SETTING_KEYS = new Set(Object.keys(getDefaults()))。
    public static var knownSettingKeys: Set<String> {
        Set(defaults.keys)
    }

    private let store: any SettingsStore
    private var cache: [String: String]?

    public init(store: any SettingsStore) {
        self.store = store
    }

    private func loadedCache() async -> [String: String] {
        if let cache { return cache }
        var loaded: [String: String] = [:]
        if let rows = try? await store.all() {
            for row in rows { loaded[row.key] = row.value }
        }
        cache = loaded
        return loaded
    }

    /// TS: get(key, defaultValue?) —— 缓存未命中 → defaultValue ?? ''。
    public func value(_ key: String, default defaultValue: String? = nil) async -> String {
        await loadedCache()[key] ?? defaultValue ?? ""
    }

    /// TS: getNumber(key, defaultValue) —— parseFloat，NaN 回退默认值。
    public func number(_ key: String, default defaultValue: Double) async -> Double {
        guard let raw = await loadedCache()[key] else { return defaultValue }
        guard let parsed = Double(raw), !parsed.isNaN else { return defaultValue }
        return parsed
    }

    /// TS: set(key, value) —— 未知 key 抛错；store.upsert + cache 双写。
    public func set(_ key: String, value: String) async throws {
        guard Self.knownSettingKeys.contains(key) else {
            throw SettingsError.unknownKey(key)
        }
        try await store.upsert(key, value: value)
        var current = await loadedCache()
        current[key] = value
        cache = current
    }

    /// TS: getAll() —— 默认值打底 + 缓存覆盖。
    public func all() async -> [String: String] {
        var result = Self.defaults
        for (key, value) in await loadedCache() {
            result[key] = value
        }
        return result
    }

    /// TS: reset() —— 默认值全量 upsert + 缓存重置。
    public func reset() async throws {
        let defaults = Self.defaults
        try await store.upsert(defaults.map { SettingRecord(key: $0.key, value: $0.value) })
        cache = defaults
    }
}

/// 设置快照：供同步世界（现有服务/路由）以值语义读取设置，
/// 取代 SettingsService 的内存缓存（异步写入仍走 SettingsAPI）。
public struct SettingsSnapshot: Sendable {
    public let values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    /// TS: get(key, defaultValue?) —— 未命中 → defaultValue ?? ''。
    public func value(_ key: String, default defaultValue: String? = nil) -> String {
        values[key] ?? defaultValue ?? ""
    }

    /// TS: getNumber(key, defaultValue) —— parseFloat，NaN 回退默认值。
    public func number(_ key: String, default defaultValue: Double) -> Double {
        guard let raw = values[key], let parsed = Double(raw), !parsed.isNaN else { return defaultValue }
        return parsed
    }
}

public extension SettingsAPI {
    /// 读取全量设置（默认值打底 + 已落库值）生成快照。
    func snapshot() async -> SettingsSnapshot {
        SettingsSnapshot(values: await all())
    }
}

/// 智能相册命名空间（album.* 命令的持久化面）。
public struct AlbumsAPI: Sendable {
    private let store: any SmartAlbumStore

    init(store: any SmartAlbumStore) {
        self.store = store
    }

    public func list() async throws -> [SmartAlbumRecord] {
        try await store.list()
    }

    public func get(id: String) async throws -> SmartAlbumRecord? {
        try await store.get(id: id)
    }

    public func create(data: SmartAlbumCreateData) async throws -> SmartAlbumRecord {
        try await store.create(data: data)
    }

    public func update(id: String, data: SmartAlbumUpdateData) async throws {
        try await store.update(id: id, data: data)
    }

    public func delete(id: String) async throws {
        try await store.delete(id: id)
    }
}

/// 模板命名空间：CRUD + apply 的领域校验（设置落库由调用方经 SettingsAPI 完成）。
public struct TemplatesAPI: Sendable {
    private let templates: any TemplateStore
    private let sessions: any SessionStore

    init(templates: any TemplateStore, sessions: any SessionStore) {
        self.templates = templates
        self.sessions = sessions
    }

    public func list() async throws -> [TemplateData] {
        try await templates.list()
    }

    public func get(id: String) async throws -> TemplateData? {
        try await templates.get(id: id)
    }

    public func create(name: String, description: String, config: WorkflowTemplateConfig) async throws -> TemplateData {
        try await templates.create(name: name, description: description, config: config)
    }

    public func update(id: String, fields: TemplateUpdateFields) async throws -> TemplateData? {
        try await templates.update(id: id, fields: fields)
    }

    public func delete(id: String) async throws {
        try await templates.delete(id: id)
    }

    /// TS: template.apply —— 校验模板与会话状态（draft/photos_loaded），
    /// 返回待写入的设置项（键序固定）；落库由调用方经 SettingsAPI 逐项写入。
    public func applyUpdates(templateId: String, sessionId: String) async throws -> [TemplateSettingUpdate] {
        guard let template = try await templates.get(id: templateId) else {
            throw TemplateError.templateNotFound
        }
        guard let session = try await sessions.get(id: sessionId) else {
            throw TemplateError.sessionNotFound
        }
        let allowed = ["draft", "photos_loaded"]
        guard allowed.contains(session.status) else {
            throw TemplateError.invalidSessionStatus(session.status)
        }

        let config = template.config
        return [
            TemplateSettingUpdate(key: "default_threshold", value: String(config.similarity.threshold)),
            TemplateSettingUpdate(key: "default_min_group_size", value: String(config.similarity.minGroupSize)),
            TemplateSettingUpdate(key: "default_eps", value: String(config.face.eps)),
            TemplateSettingUpdate(key: "default_min_samples", value: String(config.face.minSamples)),
            TemplateSettingUpdate(key: "detect_confidence", value: String(config.face.detectorConfidence)),
        ]
    }
}

/// 模板领域错误（TS 消息逐字对齐；原 TemplateServiceError 迁入 API 层）。
public enum TemplateError: Error, Equatable {
    /// TS: Error('TEMPLATE_NOT_FOUND')
    case templateNotFound
    /// TS: Error('SESSION_NOT_FOUND')
    case sessionNotFound
    /// TS: 消息形如 Cannot apply template to session with status "<status>". Expected draft or photos_loaded.
    case invalidSessionStatus(String)
}

extension TemplateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .templateNotFound: "TEMPLATE_NOT_FOUND"
        case .sessionNotFound: "SESSION_NOT_FOUND"
        case .invalidSessionStatus(let status):
            "Cannot apply template to session with status \"\(status)\". Expected draft or photos_loaded."
        }
    }
}

/// TS 错误码映射（invalidSessionStatus 为动态消息，无 GatherErrorCode 对应）。
extension TemplateError {
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .templateNotFound: .TEMPLATE_NOT_FOUND
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .invalidSessionStatus: nil
        }
    }
}

/// 会话命名空间。
public struct SessionsAPI: Sendable {
    private let store: any SessionStore

    init(store: any SessionStore) {
        self.store = store
    }

    public func list() async throws -> [SessionRecord] {
        try await store.list()
    }

    public func get(id: String) async throws -> SessionRecord? {
        try await store.get(id: id)
    }

    public func create(name: String, source: String, sourcePath: String, truncatedImport: Bool = false) async throws -> SessionRecord {
        try await store.create(name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
    }

    @discardableResult
    public func delete(id: String) async throws -> Bool {
        try await store.delete(id: id)
    }

    @discardableResult
    public func rename(id: String, name: String) async throws -> Bool {
        try await store.updateName(id: id, name: name)
    }

    public func updateStatus(id: String, status: String) async throws {
        try await store.updateStatus(id: id, status: status)
    }
}

/// 未知设置键错误（TS: Error(\`Unknown setting key: \${key}\`) 消息逐字一致）。
public enum SettingsError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String)

    public var description: String {
        switch self {
        case .unknownKey(let key): return "Unknown setting key: \(key)"
        }
    }
}
