// Store/SettingsStore.swift
// R1：app_settings 的唯一访问入口（取代 Database/Repositories/SettingsRepo.swift）。
import Foundation

public struct SettingRecord: Decodable, Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public protocol SettingsStore: Sendable {
    func all() async throws -> [SettingRecord]
    func get(_ key: String) async throws -> SettingRecord?
    func value(_ key: String) async throws -> String?
    func upsert(_ key: String, value: String) async throws
    func upsert(_ entries: [SettingRecord]) async throws
}

public extension SettingsStore {
    func value(_ key: String) async throws -> String? {
        try await get(key)?.value
    }

    func upsert(_ entries: [(key: String, value: String)]) async throws {
        try await upsert(entries.map { SettingRecord(key: $0.key, value: $0.value) })
    }
}

public struct SQLiteSettingsStore: SettingsStore {
    private static let upsertSQL = """
        INSERT INTO app_settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func all() async throws -> [SettingRecord] {
        try await database.query("SELECT key, value FROM app_settings").map { try $0.decode(SettingRecord.self) }
    }

    public func get(_ key: String) async throws -> SettingRecord? {
        try await database.queryOne("SELECT key, value FROM app_settings WHERE key = ?", [.text(key)])?
            .decode(SettingRecord.self)
    }

    public func upsert(_ key: String, value: String) async throws {
        try await database.run(Self.upsertSQL, [.text(key), .text(value)])
    }

    public func upsert(_ entries: [SettingRecord]) async throws {
        guard !entries.isEmpty else { return }
        try await database.transaction { db in
            for entry in entries {
                try db.run(Self.upsertSQL, [.text(entry.key), .text(entry.value)])
            }
        }
    }
}
