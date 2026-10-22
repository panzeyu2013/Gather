// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/TemplateRepo.swift
// WP3b-1：workflow_templates 仓储（TemplateService 的 SQL 下沉）。
//
// 旧实现由 TemplateService 内联 SQL 且用 SELECT *；这里改为显式列清单
// （id, name, description, config, created_at, updated_at），列序与旧
// rowToData 的位置映射一致。JSON 编解码仍留在 Application（域映射）。
import Foundation

public struct TemplateRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let configJSON: String
    public let createdAt: String
    public let updatedAt: String

    init(row: DBRow) {
        id = row[0].textValue ?? ""
        name = row[1].textValue ?? ""
        description = row[2].textValue ?? ""
        configJSON = row[3].textValue ?? "{}"
        createdAt = row[4].textValue ?? ""
        updatedAt = row[5].textValue ?? ""
    }
}

public struct TemplateUpdatePayload: Equatable, Sendable {
    public let name: String?
    public let description: String?
    public let configJSON: String?

    public init(name: String? = nil, description: String? = nil, configJSON: String? = nil) {
        self.name = name
        self.description = description
        self.configJSON = configJSON
    }

    public var isEmpty: Bool { name == nil && description == nil && configJSON == nil }
}

public final class TemplateRepo {
    private static let columns = "id, name, description, config, created_at, updated_at"

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// ORDER BY updated_at DESC（旧 SQL 逐字保留）。
    public func list() throws -> [TemplateRow] {
        try connection.prepare("SELECT \(Self.columns) FROM workflow_templates ORDER BY updated_at DESC")
            .query([])
            .map { TemplateRow(row: $0) }
    }

    public func get(id: String) throws -> TemplateRow? {
        try connection.prepare("SELECT \(Self.columns) FROM workflow_templates WHERE id = ?")
            .get([.text(id)])
            .map { TemplateRow(row: $0) }
    }

    /// INSERT 后回读；旧实现由服务层 get(id) 回读，行为一致。
    public func create(id: String, name: String, description: String, configJSON: String) throws -> TemplateRow? {
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO workflow_templates (id, name, description, config, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
          """).run([
            .text(id), .text(name), .text(description), .text(configJSON), .text(now), .text(now),
          ])
        return try get(id: id)
    }

    /// 动态 SET；无字段更新时服务层直接返回现值，不会调用本方法。
    public func update(id: String, fields: TemplateUpdatePayload) throws {
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
        if let configJSON = fields.configJSON {
            sets.append("config = ?")
            values.append(.text(configJSON))
        }
        sets.append("updated_at = ?")
        values.append(.text(nowISOString()))
        values.append(.text(id))
        _ = try connection.prepare(
            "UPDATE workflow_templates SET \(sets.joined(separator: ", ")) WHERE id = ?"
        ).run(values)
    }

    public func delete(id: String) throws {
        _ = try connection.prepare("DELETE FROM workflow_templates WHERE id = ?").run([.text(id)])
    }

    /// apply 的会话状态门禁读取。
    public func sessionStatus(id: String) throws -> String? {
        try connection.prepare("SELECT status FROM sessions WHERE id = ?")
            .get([.text(id)])?[0].textValue
    }
}
