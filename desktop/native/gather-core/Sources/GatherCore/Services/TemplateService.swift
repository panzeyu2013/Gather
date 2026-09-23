// desktop/native/gather-core/Sources/GatherCore/Services/TemplateService.swift
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

public enum TemplateServiceError: Error, Equatable {
    /// TS: Error('TEMPLATE_NOT_FOUND')
    case templateNotFound
    /// TS: Error('SESSION_NOT_FOUND')
    case sessionNotFound
    /// TS: Error(`Cannot apply template to session with status "${status}". Expected draft or photos_loaded.`)
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

// TemplateUpdateFields 已迁至 Store/TemplateStore.swift（R1 单一来源）；
// 本服务的 DB 写路径将在 R1 调用点迁移时改为 TemplateStore。

/// TS: TemplateService（desktop/src/main/services/template/template.service.ts）。
public final class TemplateService {
    private let connection: DBConnection
    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// TS: list —— ORDER BY updated_at DESC。
    public func list() throws -> [TemplateData] {
        let rows = try connection.prepare(
            "SELECT * FROM workflow_templates ORDER BY updated_at DESC"
        ).query([])
        return try rows.map { try rowToData(row: $0) }
    }

    /// TS: get。
    public func get(id: String) throws -> TemplateData? {
        guard let row = try connection.prepare(
            "SELECT * FROM workflow_templates WHERE id = ?"
        ).get([.text(id)]) else { return nil }
        return try rowToData(row: row)
    }

    /// TS: create —— id 用 UUID v4（TS crypto.randomUUID），时间戳 ISO-8601。
    public func create(name: String, description: String, config: WorkflowTemplateConfig) throws -> TemplateData {
        let id = newUUIDString()
        let now = nowISOString()
        let configJSON = try JSONValue.stringify(JSONValue.object(Self.configToJSON(config)))
        _ = try connection.prepare("""
            INSERT INTO workflow_templates (id, name, description, config, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          """).run([
            .text(id), .text(name), .text(description), .text(configJSON), .text(now), .text(now),
        ])
        guard let created = try get(id: id) else {
            throw TemplateServiceError.templateNotFound
        }
        return created
    }

    /// TS: update —— 动态 SET 子句；无字段更新时返回现值（不触碰 updated_at）。
    public func update(id: String, fields: TemplateUpdateFields) throws -> TemplateData {
        let existing = try get(id: id)
        guard let existing else { throw TemplateServiceError.templateNotFound }

        var sets: [String] = []
        var values: [DBValue?] = []
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
        _ = try connection.prepare(
            "UPDATE workflow_templates SET \(sets.joined(separator: ", ")) WHERE id = ?"
        ).run(values)
        guard let updated = try get(id: id) else {
            throw TemplateServiceError.templateNotFound
        }
        return updated
    }

    /// TS: delete。
    public func delete(id: String) throws {
        _ = try connection.prepare("DELETE FROM workflow_templates WHERE id = ?").run([.text(id)])
    }

    /// TS: apply —— 校验模板与会话状态后，返回待写入的设置项（键序固定）。
    /// 设置落库由调用方经 SettingsAPI 完成（R5：服务不再直连设置存储）。
    public func settingsUpdates(templateId: String, sessionId: String) throws -> [TemplateSettingUpdate] {
        guard let template = try get(id: templateId) else {
            throw TemplateServiceError.templateNotFound
        }
        guard let row = try connection.prepare("SELECT status FROM sessions WHERE id = ?")
            .get([.text(sessionId)]) else {
            throw TemplateServiceError.sessionNotFound
        }
        let status = row[0].textValue ?? ""
        let allowed = ["draft", "photos_loaded"]
        guard allowed.contains(status) else {
            throw TemplateServiceError.invalidSessionStatus(status)
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

    // MARK: - 内部

    /// TS: rowToData（config 为 JSON 字符串 → 对象）。
    private func rowToData(row: DBRow) throws -> TemplateData {
        let id = row[0].textValue ?? ""
        let name = row[1].textValue ?? ""
        let description = row[2].textValue ?? ""
        let configJSON = row[3].textValue ?? "{}"
        let createdAt = row[4].textValue ?? ""
        let updatedAt = row[5].textValue ?? ""
        let config = try Self.parseConfig(configJSON)
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
    private static func parseConfig(_ raw: String) throws -> WorkflowTemplateConfig {
        let value = try JSONValue.parse(raw)
        let dict: [String: JSONValue]
        if case .object(let d) = value { dict = d } else { dict = [:] }
        return try WorkflowTemplateConfig(
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
