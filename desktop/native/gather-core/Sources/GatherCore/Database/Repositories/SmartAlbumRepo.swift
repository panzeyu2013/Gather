// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/SmartAlbumRepo.swift
// TS 源: desktop/src/main/db/repositories/smart-album.repo.ts
import Foundation

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

// SmartAlbumCreateData / SmartAlbumUpdateData 已迁至 Store/SmartAlbumStore.swift（R1 单一来源）。

// filterCriteria 的类型为 Protocol/Filter.swift 的 FilterGroup（TS 同源契约，
// Codable 合成 JSON key 与 TS 逐字相同：logic / conditions / field / operator / value）。

public final class SmartAlbumRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func list() throws -> [SmartAlbumRow] {
        let rows = try connection.prepare("SELECT * FROM smart_albums ORDER BY updated_at DESC").query()
        return try rows.map { try SmartAlbumRow(row: $0) }
    }

    public func get(id: String) throws -> SmartAlbumRow? {
        guard let row = try connection.prepare("SELECT * FROM smart_albums WHERE id = ?").get([.text(id)]) else {
            return nil
        }
        return try SmartAlbumRow(row: row)
    }

    public func create(data: SmartAlbumCreateData) throws -> SmartAlbumRow {
        let id = newUUID()
        let now = nowISO()
        _ = try connection.prepare(
            "INSERT INTO smart_albums (id, schema_version, name, description, filter_criteria, sort_by, sort_order, icon, created_at, updated_at) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)"
        ).run([
            .text(id),
            .text(data.name),
            .text(data.description ?? ""),
            .text(smartAlbumFilterCriteriaJSON(data.filterCriteria)),
            .text(data.sortBy ?? "date_taken"),
            .text(data.sortOrder ?? "desc"),
            .text(data.icon ?? "📁"),
            .text(now),
            .text(now),
        ])
        return try get(id: id)!
    }

    public func update(id: String, data: SmartAlbumUpdateData) throws {
        let now = nowISO()
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
        values.append(.text(now))
        values.append(.text(id))

        _ = try connection.prepare("UPDATE smart_albums SET \(sets.joined(separator: ", ")) WHERE id = ?").run(values)
    }

    public func delete(id: String) throws {
        _ = try connection.prepare("DELETE FROM smart_albums WHERE id = ?").run([.text(id)])
    }
}

// filterCriteriaJSON 已迁至 Store/SmartAlbumStore.swift（smartAlbumFilterCriteriaJSON）。

private func newUUID() -> String {
    UUID().uuidString.lowercased()
}

private func nowISO() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
