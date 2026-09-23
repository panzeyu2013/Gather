// Store/SmartAlbumStore.swift
// R1：smart_albums 的唯一访问入口（取代 Database/Repositories/SmartAlbumRepo.swift）。
import Foundation

public struct SmartAlbumCreateData {
    public let name: String
    public let description: String?
    public let filterCriteria: FilterGroup
    public let sortBy: String?
    public let sortOrder: String?
    public let icon: String?

    public init(
        name: String,
        description: String? = nil,
        filterCriteria: FilterGroup,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        icon: String? = nil
    ) {
        self.name = name
        self.description = description
        self.filterCriteria = filterCriteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.icon = icon
    }
}

public struct SmartAlbumUpdateData {
    public let name: String?
    public let description: String?
    public let filterCriteria: FilterGroup?
    public let sortBy: String?
    public let sortOrder: String?
    public let icon: String?

    public init(
        name: String? = nil,
        description: String? = nil,
        filterCriteria: FilterGroup? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        icon: String? = nil
    ) {
        self.name = name
        self.description = description
        self.filterCriteria = filterCriteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.icon = icon
    }
}

public struct SmartAlbumRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let schemaVersion: Int
    public let name: String
    public let description: String
    public let filterCriteria: String
    public let sortBy: String
    public let sortOrder: String
    public let icon: String
    public let createdAt: String
    public let updatedAt: String

    /// filter_criteria JSON → FilterGroup（损坏数据返回 nil）。
    public var criteria: FilterGroup? {
        try? JSONDecoder().decode(FilterGroup.self, from: Data(filterCriteria.utf8))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon
        case schemaVersion = "schema_version"
        case filterCriteria = "filter_criteria"
        case sortBy = "sort_by"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// TS: JSON.stringify(data.filterCriteria)。JSONEncoder 默认 camelCase key，
/// 与 TS 对象序列化一致（field/operator/value/logic/conditions 原样存储）。
func smartAlbumFilterCriteriaJSON(_ group: FilterGroup) -> String {
    guard let data = try? JSONEncoder().encode(group) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

public protocol SmartAlbumStore: Sendable {
    func list() async throws -> [SmartAlbumRecord]
    func get(id: String) async throws -> SmartAlbumRecord?
    func create(data: SmartAlbumCreateData) async throws -> SmartAlbumRecord
    func update(id: String, data: SmartAlbumUpdateData) async throws
    func delete(id: String) async throws
}

public struct SQLiteSmartAlbumStore: SmartAlbumStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func list() async throws -> [SmartAlbumRecord] {
        try await database.query("SELECT * FROM smart_albums ORDER BY updated_at DESC")
            .map { try $0.decode(SmartAlbumRecord.self) }
    }

    public func get(id: String) async throws -> SmartAlbumRecord? {
        try await database.queryOne("SELECT * FROM smart_albums WHERE id = ?", [.text(id)])?
            .decode(SmartAlbumRecord.self)
    }

    public func create(data: SmartAlbumCreateData) async throws -> SmartAlbumRecord {
        let id = newUUIDString()
        let now = nowISOString()
        try await database.run(
            """
            INSERT INTO smart_albums
              (id, schema_version, name, description, filter_criteria, sort_by, sort_order, icon, created_at, updated_at)
            VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id),
                .text(data.name),
                .text(data.description ?? ""),
                .text(smartAlbumFilterCriteriaJSON(data.filterCriteria)),
                .text(data.sortBy ?? "date_taken"),
                .text(data.sortOrder ?? "desc"),
                .text(data.icon ?? "📁"),
                .text(now),
                .text(now),
            ]
        )
        guard let record = try await get(id: id) else {
            throw SQLiteFailure(phase: .other, code: 0, extended: 0, message: "smart album row missing after insert: \(id)")
        }
        return record
    }

    public func update(id: String, data: SmartAlbumUpdateData) async throws {
        var sets: [String] = []
        var values: [SQLiteValue] = []

        if let name = data.name {
            sets.append("name = ?")
            values.append(.text(name))
        }
        if let description = data.description {
            sets.append("description = ?")
            values.append(.text(description))
        }
        if let filterCriteria = data.filterCriteria {
            sets.append("filter_criteria = ?")
            values.append(.text(smartAlbumFilterCriteriaJSON(filterCriteria)))
        }
        if let sortBy = data.sortBy {
            sets.append("sort_by = ?")
            values.append(.text(sortBy))
        }
        if let sortOrder = data.sortOrder {
            sets.append("sort_order = ?")
            values.append(.text(sortOrder))
        }
        if let icon = data.icon {
            sets.append("icon = ?")
            values.append(.text(icon))
        }
        if sets.isEmpty { return }

        sets.append("updated_at = ?")
        values.append(.text(nowISOString()))
        values.append(.text(id))
        try await database.run("UPDATE smart_albums SET \(sets.joined(separator: ", ")) WHERE id = ?", values)
    }

    public func delete(id: String) async throws {
        try await database.run("DELETE FROM smart_albums WHERE id = ?", [.text(id)])
    }
}
