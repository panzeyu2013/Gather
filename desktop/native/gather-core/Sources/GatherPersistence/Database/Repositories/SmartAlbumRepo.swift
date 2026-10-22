// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/SmartAlbumRepo.swift
// TS 源: desktop/src/main/db/repositories/smart-album.repo.ts
import Foundation
import GatherProtocol

/// smart_albums 表行（列序与表定义一致）。
public struct SmartAlbumRow: Equatable, Sendable {
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

    init(row: DBRow) throws {
        guard row.count >= 10 else { throw DBError.message("SmartAlbumRow 列数不足: \(row.count)") }
        id = row[0].textValue ?? ""
        schemaVersion = Int(row[1].intValue ?? 0)
        name = row[2].textValue ?? ""
        description = row[3].textValue ?? ""
        filterCriteria = row[4].textValue ?? ""
        sortBy = row[5].textValue ?? ""
        sortOrder = row[6].textValue ?? ""
        icon = row[7].textValue ?? ""
        createdAt = row[8].textValue ?? ""
        updatedAt = row[9].textValue ?? ""
    }
}

public struct SmartAlbumCreateData {
    public let name: String
    public let description: String?
    public let filterCriteria: FilterGroup
    public let sortBy: String?
    public let sortOrder: String?
    public let icon: String?

    public init(name: String, description: String? = nil, filterCriteria: FilterGroup, sortBy: String? = nil, sortOrder: String? = nil, icon: String? = nil) {
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

    public init(name: String? = nil, description: String? = nil, filterCriteria: FilterGroup? = nil, sortBy: String? = nil, sortOrder: String? = nil, icon: String? = nil) {
        self.name = name
        self.description = description
        self.filterCriteria = filterCriteria
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.icon = icon
    }
}

// filterCriteria 的类型为 Protocol/Filter.swift 的 FilterGroup（TS 同源契约，
// Codable 合成 JSON key 与 TS 逐字相同：logic / conditions / field / operator / value）。

public final class SmartAlbumRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func list() throws -> [SmartAlbumRow] {
        // smart_albums：10 列（TableColumns.smartAlbums，列序 = SmartAlbumRow 0-9）
        let rows = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.smartAlbums)) FROM smart_albums ORDER BY updated_at DESC").query()
        return try rows.map { try SmartAlbumRow(row: $0) }
    }

    public func get(id: String) throws -> SmartAlbumRow? {
        // smart_albums：10 列（TableColumns.smartAlbums）
        guard let row = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.smartAlbums)) FROM smart_albums WHERE id = ?").get([.text(id)]) else {
            return nil
        }
        return try SmartAlbumRow(row: row)
    }

    public func create(data: SmartAlbumCreateData) throws -> SmartAlbumRow {
        let id = newUUIDString()
        let now = nowISOString()
        _ = try connection.prepare(
            "INSERT INTO smart_albums (id, filter_schema_version, name, description, filter_criteria, sort_by, sort_order, icon, created_at, updated_at) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)"
        ).run([
            .text(id),
            .text(data.name),
            .text(data.description ?? ""),
            .text(filterCriteriaJSON(data.filterCriteria)),
            .text(data.sortBy ?? "date_taken"),
            .text(data.sortOrder ?? "desc"),
            .text(data.icon ?? "📁"),
            .text(now),
            .text(now),
        ])
        return try get(id: id)!
    }

    public func update(id: String, data: SmartAlbumUpdateData) throws {
        let now = nowISOString()
        var sets: [String] = []
        var values: [DBValue?] = []

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
            values.append(.text(filterCriteriaJSON(filterCriteria)))
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
        values.append(.text(now))
        values.append(.text(id))

        _ = try connection.prepare("UPDATE smart_albums SET \(sets.joined(separator: ", ")) WHERE id = ?").run(values)
    }

    public func delete(id: String) throws {
        _ = try connection.prepare("DELETE FROM smart_albums WHERE id = ?").run([.text(id)])
    }
}

/// TS: JSON.stringify(data.filterCriteria)。JSONEncoder 默认 camelCase key，
/// 与 TS 对象序列化一致（field/operator/value/logic/conditions 原样存储）。
private func filterCriteriaJSON(_ group: FilterGroup) -> String {
    guard let data = try? JSONEncoder().encode(group) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

