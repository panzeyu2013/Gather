// desktop/native/gather-core/Sources/GatherDomain/Services/TemplateService.swift
// TS 源: desktop/src/main/services/template/template.service.ts（Phase 3.5 移植，
// 全量：list / get / create / update / delete / apply）
//
// 移植差异说明：
// - 错误对齐：update/apply 抛 TEMPLATE_NOT_FOUND，apply 抛 SESSION_NOT_FOUND
//   与 `Cannot apply template to session with status "<X>". Expected draft or
//   photos_loaded.`（逐字对齐 TS error.message）。
// - id 生成：TS crypto.randomUUID()，Swift 用 newUUIDString()（同 UUID v4）。
// - apply 经 SettingsService.set 落库并同步内存缓存（TS 注释：直接 INSERT
//   会让应用值重启后才生效；SettingsService 亦强制已知键白名单）。
import Foundation
import GatherPersistence
import GatherProtocol

public enum TemplateServiceError: Error, Equatable {
    /// TS: Error('TEMPLATE_NOT_FOUND')
    case templateNotFound
    /// TS: Error('SESSION_NOT_FOUND')
    case sessionNotFound
    /// TS: Error(`Cannot apply template to session with status "\(status)". Expected draft or photos_loaded.`)
    case invalidSessionStatus(String)
}

/// TS 错误消息逐字对齐。
extension TemplateServiceError: CustomStringConvertible {
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
extension TemplateServiceError {
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .templateNotFound: .TEMPLATE_NOT_FOUND
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .invalidSessionStatus: nil
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

/// TS: TemplateService（desktop/src/main/services/template/template.service.ts）。
public final class TemplateService {
    private let templates: any TemplateRepository
    private let settings: SettingsService

    public init(templates: any TemplateRepository, settings: SettingsService) {
        self.templates = templates
        self.settings = settings
    }

    /// TS: list —— ORDER BY updated_at DESC。
    public func list() throws -> [TemplateData] {
        try templates.list().map { try rowToData(row: $0) }
    }

    /// TS: get。
    public func get(id: String) throws -> TemplateData? {
        guard let row = try templates.get(id: id) else { return nil }
        return try rowToData(row: row)
    }

    /// TS: create —— id 用 UUID v4（TS crypto.randomUUID），时间戳 ISO-8601。
    public func create(name: String, description: String, config: WorkflowTemplateConfig) throws -> TemplateData {
        let id = newUUIDString()
        let configJSON = try JSONValue.stringify(JSONValue.object(Self.configToJSON(config)))
        guard let created = try templates.create(
            id: id,
            name: name,
            description: description,
            configJSON: configJSON
        ) else {
            throw TemplateServiceError.templateNotFound
        }
        return try rowToData(row: created)
    }

    /// TS: update —— 动态 SET 子句；无字段更新时返回现值（不触碰 updated_at）。
    public func update(id: String, fields: TemplateUpdateFields) throws -> TemplateData {
        let existing = try get(id: id)
        guard let existing else { throw TemplateServiceError.templateNotFound }

        let payload = TemplateUpdatePayload(
            name: fields.name,
            description: fields.description,
            configJSON: try fields.config.map {
                try JSONValue.stringify(JSONValue.object(Self.configToJSON($0)))
            }
        )
        if payload.isEmpty { return existing }

        try templates.update(id: id, fields: payload)
        guard let updated = try templates.get(id: id) else {
            throw TemplateServiceError.templateNotFound
        }
        return try rowToData(row: updated)
    }

    /// TS: delete。
    public func delete(id: String) throws {
        try templates.delete(id: id)
    }

    /// TS: apply —— 模板配置经 SettingsService 落库（内存缓存同步 + 白名单）。
    public func apply(templateId: String, sessionId: String) throws {
        guard let template = try get(id: templateId) else {
            throw TemplateServiceError.templateNotFound
        }
        guard let status = try templates.sessionStatus(id: sessionId) else {
            throw TemplateServiceError.sessionNotFound
        }
        let allowed = ["draft", "photos_loaded"]
        guard allowed.contains(status) else {
            throw TemplateServiceError.invalidSessionStatus(status)
        }

        let config = template.config
        // 经 SettingsService.set 而非直接 INSERT：内存缓存同步 + 已知键白名单
        //（TS 注释；未知键抛 SettingsError.unknownKey）。
        try settings.set("default_threshold", value: String(config.similarity.threshold))
        try settings.set("default_min_group_size", value: String(config.similarity.minGroupSize))
        try settings.set("default_eps", value: String(config.face.eps))
        try settings.set("default_min_samples", value: String(config.face.minSamples))
        try settings.set("detect_confidence", value: String(config.face.detectorConfidence))
    }

    // MARK: - 内部

    /// TS: rowToData（config 为 JSON 字符串 → 对象）。
    private func rowToData(row: TemplateRow) throws -> TemplateData {
        let config = try Self.parseConfig(row.configJSON)
        return TemplateData(
            id: row.id,
            name: row.name,
            description: row.description,
            config: config,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// TS: JSON.parse(row.config)。畸形 JSON 抛错对齐 TS JSON.parse；
    /// 解析成功但非对象（如 "[]"）按空对象处理（TS 的 undefined 字段语义）。
    private static func parseConfig(_ raw: String) throws -> WorkflowTemplateConfig {
        let value = try JSONValue.parse(raw)
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

    /// WorkflowTemplateConfig → JSON 对象（TS JSON.stringify 的插入序不保证，
    /// 消费方按 JSON 语义解析）。
    private static func configToJSON(_ config: WorkflowTemplateConfig) -> [String: JSONValue] {
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
