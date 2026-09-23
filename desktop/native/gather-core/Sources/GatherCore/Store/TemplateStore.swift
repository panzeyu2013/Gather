// Store/TemplateStore.swift
// R1：workflow_templates 的唯一访问入口（从 Services/TemplateService.swift 抽出内联 SQL，
// 使 Store 成为 SQL 所有者；TemplateService 仅保留 apply 的领域编排）。
import Foundation

public enum TemplateStoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case notFound
    case malformedConfig(String)

    public var description: String {
        switch self {
        case .notFound: return "TEMPLATE_NOT_FOUND"
        case .malformedConfig(let detail): return "TEMPLATE_CONFIG_INVALID: \(detail)"
        }
    }
}

/// TS: TemplateService.update 的 fields（Partial<{ name, description, config }>）。
public struct TemplateUpdateFields: Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var config: WorkflowTemplateConfig?

    public init(name: String? = nil, description: String? = nil, config: WorkflowTemplateConfig? = nil) {
        self.name = name
        self.description = description
        self.config = config
    }
}

/// 模板应用后待写入的设置项。
public struct TemplateSettingUpdate: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public protocol TemplateStore: Sendable {
    func list() async throws -> [TemplateData]
    func get(id: String) async throws -> TemplateData?
    func create(name: String, description: String, config: WorkflowTemplateConfig) async throws -> TemplateData
    func update(id: String, fields: TemplateUpdateFields) async throws -> TemplateData?
    func delete(id: String) async throws
}

public struct SQLiteTemplateStore: TemplateStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func list() async throws -> [TemplateData] {
        try await database.query("SELECT * FROM workflow_templates ORDER BY updated_at DESC")
            .map { try Self.rowToData($0) }
    }

    public func get(id: String) async throws -> TemplateData? {
        try await database.queryOne("SELECT * FROM workflow_templates WHERE id = ?", [.text(id)])
            .map { try Self.rowToData($0) }
    }

    public func create(name: String, description: String, config: WorkflowTemplateConfig) async throws -> TemplateData {
        let id = newUUIDString()
        let now = nowISOString()
        let configJSON = try JSONValue.stringify(JSONValue.object(Self.configToJSON(config)))
        try await database.run(
            """
            INSERT INTO workflow_templates (id, name, description, config, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(id), .text(name), .text(description), .text(configJSON), .text(now), .text(now)]
        )
        guard let created = try await get(id: id) else {
            throw TemplateStoreError.notFound
        }
        return created
    }

    /// 动态 SET 子句；无字段更新时返回现值（不触碰 updated_at）。
    public func update(id: String, fields: TemplateUpdateFields) async throws -> TemplateData? {
        guard let existing = try await get(id: id) else { return nil }

        var sets: [String] = []
        var values: [SQLiteValue] = []
        if let name = fields.name {
            sets.append("name = ?")
            values.append(.text(name))
        }
        if let description = fields.description {
            sets.append("description = ?")
            values.append(.text(description))
        }
        if let config = fields.config {
            sets.append("config = ?")
            values.append(.text(try JSONValue.stringify(JSONValue.object(Self.configToJSON(config)))))
        }
        if sets.isEmpty { return existing }

        sets.append("updated_at = ?")
        values.append(.text(nowISOString()))
        values.append(.text(id))
        try await database.run(
            "UPDATE workflow_templates SET \(sets.joined(separator: ", ")) WHERE id = ?",
            values
        )
        guard let updated = try await get(id: id) else {
            throw TemplateStoreError.notFound
        }
        return updated
    }

    public func delete(id: String) async throws {
        try await database.run("DELETE FROM workflow_templates WHERE id = ?", [.text(id)])
    }

    // MARK: 行 ↔ 领域 DTO

    static func rowToData(_ row: SQLiteRow) throws -> TemplateData {
        let id = row.text("id") ?? ""
        let name = row.text("name") ?? ""
        let description = row.text("description") ?? ""
        let configJSON = row.text("config") ?? "{}"
        let createdAt = row.text("created_at") ?? ""
        let updatedAt = row.text("updated_at") ?? ""
        let config = try parseConfig(configJSON)
        return TemplateData(
            id: id,
            name: name,
            description: description,
            config: config,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// TS: JSON.parse(row.config)。畸形 JSON 抛错对齐 TS JSON.parse；
    /// 解析成功但非对象（如 "[]"）按空对象处理（TS 的 undefined 字段语义）。
    static func parseConfig(_ raw: String) throws -> WorkflowTemplateConfig {
        let value: JSONValue
        do {
            value = try JSONValue.parse(raw)
        } catch {
            throw TemplateStoreError.malformedConfig(String(describing: error))
        }
        let dict: [String: JSONValue]
        if case .object(let d) = value { dict = d } else { dict = [:] }
        return WorkflowTemplateConfig(
            similarity: WorkflowTemplateSimilarity(
                threshold: dict.double("similarity", "threshold"),
                minGroupSize: dict.int("similarity", "minGroupSize")
            ),
            face: WorkflowTemplateFace(
                eps: dict.double("face", "eps"),
                minSamples: dict.int("face", "minSamples"),
                detectorConfidence: dict.double("face", "detectorConfidence")
            ),
            faceLibrary: WorkflowTemplateFaceLibrary(
                enabled: dict.bool("faceLibrary", "enabled"),
                matchThreshold: dict.double("faceLibrary", "matchThreshold")
            ),
            duplicate: WorkflowTemplateDuplicate(
                enabled: dict.bool("duplicate", "enabled"),
                visualThreshold: dict.double("duplicate", "visualThreshold")
            ),
            writeback: WorkflowTemplateWriteback(
                createAlbums: dict.bool("writeback", "createAlbums"),
                addPrefix: dict.bool("writeback", "addPrefix"),
                markUngrouped: dict.bool("writeback", "markUngrouped"),
                writeIPTC: dict.bool("writeback", "writeIPTC")
            )
        )
    }

    /// WorkflowTemplateConfig → JSON 对象。
    static func configToJSON(_ config: WorkflowTemplateConfig) -> [String: JSONValue] {
        [
            "similarity": .object([
                "threshold": .real(config.similarity.threshold),
                "minGroupSize": .int(Int64(config.similarity.minGroupSize)),
            ]),
            "face": .object([
                "eps": .real(config.face.eps),
                "minSamples": .int(Int64(config.face.minSamples)),
                "detectorConfidence": .real(config.face.detectorConfidence),
            ]),
            "faceLibrary": .object([
                "enabled": .bool(config.faceLibrary.enabled),
                "matchThreshold": .real(config.faceLibrary.matchThreshold),
            ]),
            "duplicate": .object([
                "enabled": .bool(config.duplicate.enabled),
                "visualThreshold": .real(config.duplicate.visualThreshold),
            ]),
            "writeback": .object([
                "createAlbums": .bool(config.writeback.createAlbums),
                "addPrefix": .bool(config.writeback.addPrefix),
                "markUngrouped": .bool(config.writeback.markUngrouped),
                "writeIPTC": .bool(config.writeback.writeIPTC),
            ]),
        ]
    }
}

// MARK: - JSONValue 读取辅助

private extension Dictionary where Key == String, Value == JSONValue {
    func nested(_ key: String) -> [String: JSONValue]? {
        guard let value = self[key], case .object(let dict) = value else { return nil }
        return dict
    }

    func double(_ root: String, _ key: String) -> Double {
        guard let value = nested(root)?[key], case .number(let v) = value else { return 0 }
        return v
    }

    func int(_ root: String, _ key: String) -> Int {
        guard let value = nested(root)?[key], case .number(let v) = value else { return 0 }
        return Int(v)
    }

    func bool(_ root: String, _ key: String) -> Bool {
        guard let value = nested(root)?[key], case .bool(let v) = value else { return false }
        return v
    }
}
