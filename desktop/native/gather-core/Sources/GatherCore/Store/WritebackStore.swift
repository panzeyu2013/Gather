// Store/WritebackStore.swift
// R1：metadata_outbox / metadata_outbox_sessions 的唯一访问入口
// （取代 Database/Repositories/MetadataOutboxRepo.swift；writeback_items 部分随后并入）。
import Foundation

public struct OutboxRecord: Decodable, Equatable, Sendable {
    public let xmpPath: String
    public let ownerSessionId: String?
    public let createdBySessionId: String?
    public let photoPath: String
    public let patchJSON: String
    public let dirtyFields: String
    public let sourceModule: String
    public let revision: Int64
    public let persistedRevision: Int64
    public let baseFingerprint: String
    public let baseValuesJSON: String
    public let backupPath: String
    public let status: String
    public let attemptCount: Int64
    public let errorMessage: String
    public let updatedAt: String

    public var patch: JSONValue {
        (try? JSONValue.parse(patchJSON)) ?? JSONValue.object([:])
    }

    public var dirty: [String] {
        ((try? JSONValue.parse(dirtyFields)) as JSONValue?)?.arrayValue ?? []
    }

    enum CodingKeys: String, CodingKey {
        case xmpPath = "xmp_path"
        case ownerSessionId = "owner_session_id"
        case createdBySessionId = "created_by_session_id"
        case photoPath = "photo_path"
        case patchJSON = "patch_json"
        case dirtyFields = "dirty_fields"
        case sourceModule = "source_module"
        case revision
        case persistedRevision = "persisted_revision"
        case baseFingerprint = "base_fingerprint"
        case baseValuesJSON = "base_values_json"
        case backupPath = "backup_path"
        case status
        case attemptCount = "attempt_count"
        case errorMessage = "error_message"
        case updatedAt = "updated_at"
    }
}

/// 摘要投影：供 summary push 使用，不含重型 JSON 列。
public struct OutboxSummary: Decodable, Equatable, Sendable {
    public let xmpPath: String
    public let revision: Int64
    public let persistedRevision: Int64
    public let status: String
    public let attemptCount: Int64
    public let errorMessage: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case xmpPath = "xmp_path"
        case revision
        case persistedRevision = "persisted_revision"
        case status
        case attemptCount = "attempt_count"
        case errorMessage = "error_message"
        case updatedAt = "updated_at"
    }
}

public protocol WritebackStore: Sendable {
    func outboxEntry(xmpPath: String) async throws -> OutboxRecord?
    func outboxEntries(sessionId: String) async throws -> [OutboxRecord]
    func outboxSummaries(sessionId: String) async throws -> [OutboxSummary]
    func outboxSessionIds(xmpPath: String) async throws -> [String]
    func outboxCounts(sessionId: String) async throws -> [String: Int64]
    func hasActiveOtherModule(sessionId: String, module: String) async throws -> Bool
    func recoverableOutbox() async throws -> [OutboxRecord]
    func recoverableActiveOutbox() async throws -> [OutboxRecord]
    func orphanOutbox() async throws -> [OutboxRecord]
    func mergeOutboxPatch(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) async throws -> OutboxRecord
    func claimOutbox(xmpPath: String, expectedRevision: Int64) async throws -> Bool
    func markOutboxWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) async throws
    func markOutboxStatus(xmpPath: String, status: String, errorMessage: String) async throws
    func resetOutboxForRetry(xmpPath: String) async throws
    func setOutboxBackupPath(xmpPath: String, backupPath: String) async throws
    func initializeOutboxBaseline(xmpPath: String, baselineFingerprint: String, baselineValues: JSONValue) async throws
    func recoverInterruptedOutbox() async throws
    func resolveOutboxConflict(
        xmpPath: String,
        patch: JSONValue,
        dirtyFields: [String],
        baselineFingerprint: String,
        baselineValues: JSONValue,
        acceptRemote: Bool
    ) async throws
    func markSessionSynced(sessionId: String, sourceModule: String) async throws
    func deleteOutbox(xmpPath: String) async throws
    func clearOutboxBackupPath(xmpPath: String, backupPath: String) async throws
    func deleteOutboxByRevision(xmpPath: String, revision: Int64) async throws
    func discardModulePending(sessionId: String, sourceModule: String) async throws
}

public extension WritebackStore {
    func markOutboxStatus(xmpPath: String, status: String) async throws {
        try await markOutboxStatus(xmpPath: xmpPath, status: status, errorMessage: "")
    }
}

public struct SQLiteWritebackStore: WritebackStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: 查询

    public func outboxEntry(xmpPath: String) async throws -> OutboxRecord? {
        try await database.queryOne("SELECT * FROM metadata_outbox WHERE xmp_path = ?", [.text(xmpPath)])?
            .decode(OutboxRecord.self)
    }

    public func outboxEntries(sessionId: String) async throws -> [OutboxRecord] {
        try await database.query(
            """
            SELECT o.*
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
            ORDER BY o.updated_at, o.xmp_path
            """,
            [.text(sessionId)]
        ).map { try $0.decode(OutboxRecord.self) }
    }

    public func outboxSummaries(sessionId: String) async throws -> [OutboxSummary] {
        try await database.query(
            """
            SELECT o.xmp_path, o.revision, o.persisted_revision, o.status,
                   o.attempt_count, o.error_message, o.updated_at
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
            ORDER BY o.updated_at, o.xmp_path
            """,
            [.text(sessionId)]
        ).map { try $0.decode(OutboxSummary.self) }
    }

    public func outboxSessionIds(xmpPath: String) async throws -> [String] {
        try await database.query(
            "SELECT session_id FROM metadata_outbox_sessions WHERE xmp_path = ? ORDER BY linked_at, session_id",
            [.text(xmpPath)]
        ).compactMap { $0.text("session_id") }
    }

    public func outboxCounts(sessionId: String) async throws -> [String: Int64] {
        let rows = try await database.query(
            """
            SELECT o.status, COUNT(*) AS count
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
            GROUP BY o.status
            """,
            [.text(sessionId)]
        )
        var counts: [String: Int64] = [:]
        for row in rows {
            counts[row.text("status") ?? ""] = row.int("count") ?? 0
        }
        return counts
    }

    public func hasActiveOtherModule(sessionId: String, module: String) async throws -> Bool {
        try await database.queryOne(
            """
            SELECT 1
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
              AND o.source_module IN ('face-keyword', 'similarity', 'template')
              AND o.source_module != ?
              AND o.status IN ('written', 'synced')
            LIMIT 1
            """,
            [.text(sessionId), .text(module)]
        ) != nil
    }

    public func recoverableOutbox() async throws -> [OutboxRecord] {
        try await database.query(
            """
            SELECT * FROM metadata_outbox
            WHERE status IN ('pending', 'writing', 'failed')
            ORDER BY updated_at
            """
        ).map { try $0.decode(OutboxRecord.self) }
    }

    public func recoverableActiveOutbox() async throws -> [OutboxRecord] {
        try await database.query(
            """
            SELECT *
            FROM metadata_outbox
            WHERE status IN ('pending', 'writing', 'failed')
              AND EXISTS (
                SELECT 1 FROM metadata_outbox_sessions os
                WHERE os.xmp_path = metadata_outbox.xmp_path
              )
            ORDER BY updated_at
            """
        ).map { try $0.decode(OutboxRecord.self) }
    }

    public func orphanOutbox() async throws -> [OutboxRecord] {
        try await database.query(
            """
            SELECT o.*
            FROM metadata_outbox o
            WHERE NOT EXISTS (
              SELECT 1 FROM metadata_outbox_sessions os WHERE os.xmp_path = o.xmp_path
            )
            ORDER BY o.updated_at DESC
            """
        ).map { try $0.decode(OutboxRecord.self) }
    }

    // MARK: 写入

    /// 读-改-写整体入事务：并发会话共享同一 sidecar 时避免 revision 相同互相覆盖。
    public func mergeOutboxPatch(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) async throws -> OutboxRecord {
        try await database.transaction { db in
            let existing = try Self.outboxEntry(db, xmpPath: xmpPath)
            var existingPatch = JSONValue.object([:])
            var existingDirty: [String] = []
            if let existing {
                let startsNewRevision =
                    existing.persistedRevision == existing.revision &&
                    ["written", "synced", "clean", "cleaned"].contains(existing.status)
                if !startsNewRevision {
                    existingPatch = (try? JSONValue.parse(existing.patchJSON)) ?? JSONValue.object([:])
                    existingDirty = ((try? JSONValue.parse(existing.dirtyFields)) as JSONValue?)?.arrayValue ?? []
                }
            }
            let mergedPatch = Self.mergeObjects(existingPatch, patch)
            var mergedDirty: [String] = []
            for field in existingDirty + dirtyFields where !mergedDirty.contains(field) {
                mergedDirty.append(field)
            }
            let sourceModule = patch["source"]?.stringValue ?? ""
            let resolvedSource = sourceModule.isEmpty ? "manual" : sourceModule
            let revision = (existing?.revision ?? 0) + 1
            let now = nowISOString()

            try db.run(
                """
                INSERT INTO metadata_outbox (
                  xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json, dirty_fields,
                  source_module, revision, persisted_revision, base_fingerprint, base_values_json,
                  backup_path, status, attempt_count, error_message, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, '', '{}', '', 'pending', 0, '', ?)
                ON CONFLICT(xmp_path) DO UPDATE SET
                  photo_path = excluded.photo_path,
                  patch_json = excluded.patch_json,
                  dirty_fields = excluded.dirty_fields,
                  source_module = excluded.source_module,
                  revision = excluded.revision,
                  status = 'pending',
                  attempt_count = 0,
                  error_message = '',
                  updated_at = excluded.updated_at
                """,
                [
                    .text(xmpPath), .text(sessionId), .text(sessionId), .text(photoPath),
                    .text(try JSONValue.stringify(mergedPatch)),
                    .text(try JSONValue.stringify(JSONValue.array(mergedDirty.map { JSONValue.string($0) }))),
                    .text(resolvedSource), .int(revision), .text(now),
                ]
            )
            try db.run(
                """
                INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
                VALUES (?, ?, '', ?)
                ON CONFLICT(xmp_path, session_id) DO UPDATE SET confirmed_at = ''
                """,
                [.text(xmpPath), .text(sessionId), .text(now)]
            )
            try db.run("UPDATE metadata_outbox_sessions SET confirmed_at = '' WHERE xmp_path = ?", [.text(xmpPath)])
            guard let record = try Self.outboxEntry(db, xmpPath: xmpPath) else {
                throw SQLiteFailure(phase: .other, code: 0, extended: 0, message: "outbox row missing after merge: \(xmpPath)")
            }
            return record
        }
    }

    public func claimOutbox(xmpPath: String, expectedRevision: Int64) async throws -> Bool {
        try await database.run(
            """
            UPDATE metadata_outbox
            SET status = 'writing', attempt_count = attempt_count + 1, updated_at = ?
            WHERE xmp_path = ? AND revision = ? AND status IN ('pending', 'failed')
            """,
            [.text(nowISOString()), .text(xmpPath), .int(expectedRevision)]
        ) == 1
    }

    public func markOutboxWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) async throws {
        try await database.run(
            """
            UPDATE metadata_outbox
            SET persisted_revision = ?, base_fingerprint = ?, base_values_json = ?, backup_path = ?,
                status = CASE WHEN revision = ? THEN 'written' ELSE 'pending' END,
                error_message = '', updated_at = ?
            WHERE xmp_path = ?
            """,
            [
                .int(revision), .text(fingerprint), .text(try JSONValue.stringify(baseValues)),
                .text(backupPath), .int(revision), .text(nowISOString()), .text(xmpPath),
            ]
        )
    }

    public func markOutboxStatus(xmpPath: String, status: String, errorMessage: String = "") async throws {
        try await database.run(
            "UPDATE metadata_outbox SET status = ?, error_message = ?, updated_at = ? WHERE xmp_path = ?",
            [.text(status), .text(errorMessage), .text(nowISOString()), .text(xmpPath)]
        )
    }

    public func resetOutboxForRetry(xmpPath: String) async throws {
        try await database.run(
            """
            UPDATE metadata_outbox
            SET status = 'pending', attempt_count = 0, error_message = '', updated_at = ?
            WHERE xmp_path = ? AND status = 'failed'
            """,
            [.text(nowISOString()), .text(xmpPath)]
        )
    }

    public func setOutboxBackupPath(xmpPath: String, backupPath: String) async throws {
        try await database.run(
            "UPDATE metadata_outbox SET backup_path = ?, updated_at = ? WHERE xmp_path = ? AND backup_path = ''",
            [.text(backupPath), .text(nowISOString()), .text(xmpPath)]
        )
    }

    public func initializeOutboxBaseline(
        xmpPath: String,
        baselineFingerprint: String,
        baselineValues: JSONValue
    ) async throws {
        try await database.run(
            """
            UPDATE metadata_outbox
            SET base_fingerprint = ?, base_values_json = ?, updated_at = ?
            WHERE xmp_path = ? AND base_fingerprint = ''
            """,
            [.text(baselineFingerprint), .text(try JSONValue.stringify(baselineValues)), .text(nowISOString()), .text(xmpPath)]
        )
    }

    public func recoverInterruptedOutbox() async throws {
        try await database.run(
            "UPDATE metadata_outbox SET status = 'pending', updated_at = ? WHERE status = 'writing'",
            [.text(nowISOString())]
        )
    }

    public func resolveOutboxConflict(
        xmpPath: String,
        patch: JSONValue,
        dirtyFields: [String],
        baselineFingerprint: String,
        baselineValues: JSONValue,
        acceptRemote: Bool
    ) async throws {
        if acceptRemote {
            // 本地脏字段全部丢弃：删除整行，避免后续 cleanup 误删/回滚用户想保留的外部 XMP。
            try await deleteOutbox(xmpPath: xmpPath)
            return
        }
        try await database.transaction { db in
            try db.run(
                """
                UPDATE metadata_outbox
                SET patch_json = ?, dirty_fields = ?, revision = revision + 1,
                    persisted_revision = persisted_revision,
                    base_fingerprint = ?, base_values_json = ?,
                    status = 'pending', attempt_count = 0, error_message = '', updated_at = ?
                WHERE xmp_path = ? AND status = 'conflict'
                """,
                [
                    .text(try JSONValue.stringify(patch)),
                    .text(try JSONValue.stringify(JSONValue.array(dirtyFields.map { JSONValue.string($0) }))),
                    .text(baselineFingerprint), .text(try JSONValue.stringify(baselineValues)),
                    .text(nowISOString()), .text(xmpPath),
                ]
            )
            try db.run(
                "UPDATE metadata_outbox_sessions SET confirmed_at = ? WHERE xmp_path = ?",
                [.text(""), .text(xmpPath)]
            )
        }
    }

    public func markSessionSynced(sessionId: String, sourceModule: String) async throws {
        let now = nowISOString()
        try await database.transaction { db in
            try db.run(
                """
                UPDATE metadata_outbox_sessions
                SET confirmed_at = ?
                WHERE session_id = ?
                  AND xmp_path IN (
                    SELECT xmp_path FROM metadata_outbox
                    WHERE status IN ('written', 'synced') AND source_module = ?
                  )
                """,
                [.text(now), .text(sessionId), .text(sourceModule)]
            )
            try db.run(
                """
                UPDATE metadata_outbox
                SET status = 'synced', updated_at = ?
                WHERE status = 'written'
                  AND source_module = ?
                  AND EXISTS (
                    SELECT 1 FROM metadata_outbox_sessions os
                    WHERE os.xmp_path = metadata_outbox.xmp_path
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM metadata_outbox_sessions os
                    WHERE os.xmp_path = metadata_outbox.xmp_path AND os.confirmed_at = ''
                  )
                """,
                [.text(now), .text(sourceModule)]
            )
        }
    }

    public func deleteOutbox(xmpPath: String) async throws {
        try await database.run("DELETE FROM metadata_outbox WHERE xmp_path = ?", [.text(xmpPath)])
    }

    public func clearOutboxBackupPath(xmpPath: String, backupPath: String) async throws {
        try await database.run(
            "UPDATE metadata_outbox SET backup_path = ? WHERE xmp_path = ? AND backup_path = ?",
            [.text(""), .text(xmpPath), .text(backupPath)]
        )
    }

    public func deleteOutboxByRevision(xmpPath: String, revision: Int64) async throws {
        try await database.run(
            "DELETE FROM metadata_outbox WHERE xmp_path = ? AND revision = ?",
            [.text(xmpPath), .int(revision)]
        )
    }

    public func discardModulePending(sessionId: String, sourceModule: String) async throws {
        try await database.run(
            """
            DELETE FROM metadata_outbox
            WHERE source_module = ?
              AND status IN ('pending', 'failed')
              AND EXISTS (
                SELECT 1 FROM metadata_outbox_sessions os
                WHERE os.xmp_path = metadata_outbox.xmp_path AND os.session_id = ?
              )
            """,
            [.text(sourceModule), .text(sessionId)]
        )
    }

    // MARK: 事务内辅助

    private static func outboxEntry(_ db: isolated SQLiteDatabase, xmpPath: String) throws -> OutboxRecord? {
        try db.queryOne("SELECT * FROM metadata_outbox WHERE xmp_path = ?", [.text(xmpPath)])?
            .decode(OutboxRecord.self)
    }

    /// TS 展开 { ...existingPatch, ...patch }（后者覆盖前者）。
    private static func mergeObjects(_ base: JSONValue, _ overlay: JSONValue) -> JSONValue {
        guard case .object(let baseDict) = base, case .object(let overlayDict) = overlay else {
            return overlay
        }
        var merged = baseDict
        for (key, value) in overlayDict { merged[key] = value }
        return .object(merged)
    }
}
