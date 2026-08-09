// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/SettingsRepo.swift
// TS 源: desktop/src/main/db/repositories/settings.repo.ts
import Foundation

/// app_settings 表行。
public struct SettingsRow: Equatable, Sendable {
    public let key: String
    public let value: String
}

public final class SettingsRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func getAll() throws -> [SettingsRow] {
        let rows = try connection.prepare("SELECT key, value FROM app_settings").query()
        return rows.map { row in
            SettingsRow(key: row[0].textValue ?? "", value: row[1].textValue ?? "")
        }
    }

    public func get(key: String) throws -> SettingsRow? {
        guard let row = try connection.prepare("SELECT key, value FROM app_settings WHERE key = ?").get([.text(key)]) else {
            return nil
        }
        return SettingsRow(key: row[0].textValue ?? "", value: row[1].textValue ?? "")
    }

    public func upsert(key: String, value: String) throws {
        _ = try connection.prepare(
            "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        ).run([.text(key), .text(value)])
    }

    public func batchUpsert(entries: [(key: String, value: String)]) throws {
        let stmt = try connection.prepare(
            "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        try connection.transaction {
            for entry in entries {
                _ = try stmt.run([.text(entry.key), .text(entry.value)])
            }
        }
    }
}
