// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/MetadataOutboxRepo.swift
// TS 源: desktop/src/main/db/repositories/metadata-outbox.repo.ts
import Foundation

/// metadata_outbox 表行（列序与 SELECT * 一致，见 Schema.swift）。
public struct MetadataOutboxRow {
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

    public init(row: DBRow) {
        xmpPath = row[0].textValue ?? ""
        ownerSessionId = row[1].textValue
        createdBySessionId = row[2].textValue
        photoPath = row[3].textValue ?? ""
        patchJSON = row[4].textValue ?? "{}"
        dirtyFields = row[5].textValue ?? "[]"
        revision = row[6].intValue ?? 0
        persistedRevision = row[7].intValue ?? 0
        baseFingerprint = row[8].textValue ?? ""
        baseValuesJSON = row[9].textValue ?? "{}"
        backupPath = row[10].textValue ?? ""
        status = row[11].textValue ?? ""
        attemptCount = row[12].intValue ?? 0
        errorMessage = row[13].textValue ?? ""
        updatedAt = row[14].textValue ?? ""
        // 注：source_module 由 v27 ALTER TABLE 追加，位于列尾（index 15）
        sourceModule = row[15].textValue ?? ""
    }

    public var patch: JSONValue {
        (try? JSONValue.parse(patchJSON)) ?? JSONValue.object([:])
    }

    public var dirty: [String] {
        ((try? JSONValue.parse(dirtyFields)) as JSONValue?)?.arrayValue ?? []
    }
}

/// 摘要投影（SummaryRow）：供 summary push 使用，不含重型 JSON 列。
public struct MetadataOutboxSummaryRow {
    public let xmpPath: String
    public let revision: Int64
    public let persistedRevision: Int64
    public let status: String
    public let attemptCount: Int64
    public let errorMessage: String
    public let updatedAt: String

    public init(row: DBRow) {
        xmpPath = row[0].textValue ?? ""
        revision = row[1].intValue ?? 0
        persistedRevision = row[2].intValue ?? 0
        status = row[3].textValue ?? ""
        attemptCount = row[4].intValue ?? 0
        errorMessage = row[5].textValue ?? ""
        updatedAt = row[6].textValue ?? ""
    }
}

/// metadata_outbox 仓库（TS MetadataOutboxRepository）。
public final class MetadataOutboxRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func get(_ xmpPath: String) throws -> MetadataOutboxRow? {
        guard let row = try connection.prepare("SELECT * FROM metadata_outbox WHERE xmp_path = ?")
            .get([.text(xmpPath)]) else { return nil }
        return MetadataOutboxRow(row: row)
    }

    public func getBySession(_ sessionId: String) throws -> [MetadataOutboxRow] {
        let rows = try connection.prepare("""
            SELECT o.*
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
            ORDER BY o.updated_at, o.xmp_path
          """).query([.text(sessionId)])
        return rows.map { MetadataOutboxRow(row: $0) }
    }

    public func getSummaryRowsBySession(_ sessionId: String) throws -> [MetadataOutboxSummaryRow] {
        let rows = try connection.prepare("""
            SELECT o.xmp_path, o.revision, o.persisted_revision, o.status,
                   o.attempt_count, o.error_message, o.updated_at
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
            ORDER BY o.updated_at, o.xmp_path
          """).query([.text(sessionId)])
        return rows.map { MetadataOutboxSummaryRow(row: $0) }
    }

    public func getSessionIds(_ xmpPath: String) throws -> [String] {
        let rows = try connection.prepare("""
            SELECT session_id FROM metadata_outbox_sessions
            WHERE xmp_path = ? ORDER BY linked_at, session_id
          """).query([.text(xmpPath)])
        return rows.compactMap { $0[0].textValue }
    }

    public func countBySession(_ sessionId: String) throws -> [String: Int64] {
        let rows = try connection.prepare("""
            SELECT o.status, COUNT(*) AS count
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
            GROUP BY o.status
          """).query([.text(sessionId)])
        var counts: [String: Int64] = [:]
        for row in rows {
            counts[row[0].textValue ?? ""] = row[1].intValue ?? 0
        }
        return counts
    }

    public func hasActiveOtherModule(sessionId: String, module: String) throws -> Bool {
        try connection.prepare("""
            SELECT 1
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
              AND o.source_module IN ('face-keyword', 'similarity', 'template')
              AND o.source_module != ?
              AND o.status IN ('written', 'synced')
            LIMIT 1
          """).get([.text(sessionId), .text(module)]) != nil
    }

    public func getRecoverable() throws -> [MetadataOutboxRow] {
        let rows = try connection.prepare("""
            SELECT *
            FROM metadata_outbox
            WHERE status IN ('pending', 'writing', 'failed')
            ORDER BY updated_at
          """).query()
        return rows.map { MetadataOutboxRow(row: $0) }
    }

    public func getRecoverableActive() throws -> [MetadataOutboxRow] {
        let rows = try connection.prepare("""
            SELECT *
            FROM metadata_outbox
            WHERE status IN ('pending', 'writing', 'failed')
              AND EXISTS (
                SELECT 1 FROM metadata_outbox_sessions os
                WHERE os.xmp_path = metadata_outbox.xmp_path
              )
            ORDER BY updated_at
          """).query()
        return rows.map { MetadataOutboxRow(row: $0) }
    }

    public func getOrphans() throws -> [MetadataOutboxRow] {
        let rows = try connection.prepare("""
            SELECT o.*
            FROM metadata_outbox o
            WHERE NOT EXISTS (
              SELECT 1 FROM metadata_outbox_sessions os WHERE os.xmp_path = o.xmp_path
            )
            ORDER BY o.updated_at DESC
          """).query()
        return rows.map { MetadataOutboxRow(row: $0) }
    }

    public func mergePatch(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) throws -> MetadataOutboxRow {
        let existing = try get(xmpPath)
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
        let mergedPatch = mergeObjects(existingPatch, patch)
        var mergedDirty: [String] = []
        for d in existingDirty + dirtyFields where !mergedDirty.contains(d) {
            mergedDirty.append(d)
        }
        let sourceModule = patch["source"]?.stringValue ?? ""
        let resolvedSource = sourceModule.isEmpty ? "manual" : sourceModule
        let revision = (existing?.revision ?? 0) + 1
        let now = nowISOString()

        try connection.transaction {
            _ = try connection.prepare("""
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
              """).run([
                .text(xmpPath),
                .text(sessionId),
                .text(sessionId),
                .text(photoPath),
                .text(try JSONValue.stringify(mergedPatch)),
                .text(try JSONValue.stringify(JSONValue.array(mergedDirty.map { JSONValue.string($0) }))),
                .text(resolvedSource),
                .int(revision),
                .text(now),
            ])
            _ = try connection.prepare("""
                INSERT INTO metadata_outbox_sessions
                  (xmp_path, session_id, confirmed_at, linked_at)
                VALUES (?, ?, '', ?)
                ON CONFLICT(xmp_path, session_id) DO UPDATE SET confirmed_at = ''
              """).run([.text(xmpPath), .text(sessionId), .text(now)])
            _ = try connection.prepare("""
                UPDATE metadata_outbox_sessions SET confirmed_at = ''
                WHERE xmp_path = ?
              """).run([.text(xmpPath)])
        }
        return try get(xmpPath)!
    }

    public func claim(xmpPath: String, expectedRevision: Int64) throws -> Bool {
        try connection.prepare("""
            UPDATE metadata_outbox
            SET status = 'writing',
                attempt_count = attempt_count + 1,
                updated_at = ?
            WHERE xmp_path = ?
              AND revision = ?
              AND status IN ('pending', 'failed')
          """).run([.text(nowISOString()), .text(xmpPath), .int(expectedRevision)]) == 1
    }

    public func markWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET persisted_revision = ?,
                base_fingerprint = ?,
                base_values_json = ?,
                backup_path = ?,
                status = CASE WHEN revision = ? THEN 'written' ELSE 'pending' END,
                error_message = '',
                updated_at = ?
            WHERE xmp_path = ?
          """).run([
            .int(revision),
            .text(fingerprint),
            .text(try JSONValue.stringify(baseValues)),
            .text(backupPath),
            .int(revision),
            .text(nowISOString()),
            .text(xmpPath),
        ])
    }

    public func markStatus(xmpPath: String, status: String, errorMessage: String = "") throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET status = ?, error_message = ?, updated_at = ?
            WHERE xmp_path = ?
          """).run([.text(status), .text(errorMessage), .text(nowISOString()), .text(xmpPath)])
    }

    public func resetForRetry(_ xmpPath: String) throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET status = 'pending',
                attempt_count = 0,
                error_message = '',
                updated_at = ?
            WHERE xmp_path = ? AND status = 'failed'
          """).run([.text(nowISOString()), .text(xmpPath)])
    }

    public func setBackupPath(xmpPath: String, backupPath: String) throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET backup_path = ?, updated_at = ?
            WHERE xmp_path = ? AND backup_path = ''
          """).run([.text(backupPath), .text(nowISOString()), .text(xmpPath)])
    }

    public func initializeBaseline(xmpPath: String, baselineFingerprint: String, baselineValues: JSONValue) throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET base_fingerprint = ?,
                base_values_json = ?,
                updated_at = ?
            WHERE xmp_path = ? AND base_fingerprint = ''
          """).run([
            .text(baselineFingerprint),
            .text(try JSONValue.stringify(baselineValues)),
            .text(nowISOString()),
            .text(xmpPath),
        ])
    }

    public func recoverInterrupted() throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET status = 'pending', updated_at = ?
            WHERE status = 'writing'
          """).run([.text(nowISOString())])
    }

    public func resolveConflict(
        xmpPath: String,
        patch: JSONValue,
        dirtyFields: [String],
        baselineFingerprint: String,
        baselineValues: JSONValue,
        acceptRemote: Bool
    ) throws {
        if acceptRemote {
            // All local dirty fields were discarded. Keeping a synthetic "written"
            // transaction here would make cleanup delete or restore the external XMP
            // that the user explicitly chose to keep.
            try delete(xmpPath)
            return
        }
        let now = nowISOString()
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET patch_json = ?, dirty_fields = ?, revision = revision + 1,
                persisted_revision = persisted_revision,
                base_fingerprint = ?, base_values_json = ?,
                status = 'pending',
                attempt_count = 0, error_message = '', updated_at = ?
            WHERE xmp_path = ? AND status = 'conflict'
          """).run([
            .text(try JSONValue.stringify(patch)),
            .text(try JSONValue.stringify(JSONValue.array(dirtyFields.map { JSONValue.string($0) }))),
            .text(baselineFingerprint),
            .text(try JSONValue.stringify(baselineValues)),
            .text(now),
            .text(xmpPath),
        ])
        _ = try connection.prepare(
            "UPDATE metadata_outbox_sessions SET confirmed_at = ? WHERE xmp_path = ?"
        ).run([.text(""), .text(xmpPath)])
    }

    public func markSessionSynced(sessionId: String, sourceModule: String) throws {
        let now = nowISOString()
        try connection.transaction {
            _ = try connection.prepare("""
                UPDATE metadata_outbox_sessions
                SET confirmed_at = ?
                WHERE session_id = ?
                  AND xmp_path IN (
                    SELECT xmp_path FROM metadata_outbox
                    WHERE status IN ('written', 'synced') AND source_module = ?
                  )
              """).run([.text(now), .text(sessionId), .text(sourceModule)])
            _ = try connection.prepare("""
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
                    WHERE os.xmp_path = metadata_outbox.xmp_path
                      AND os.confirmed_at = ''
                  )
              """).run([.text(now), .text(sourceModule)])
        }
    }

    public func delete(_ xmpPath: String) throws {
        _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ?").run([.text(xmpPath)])
    }

    public func clearBackupPath(xmpPath: String, backupPath: String) throws {
        _ = try connection.prepare(
            "UPDATE metadata_outbox SET backup_path = ? WHERE xmp_path = ? AND backup_path = ?"
        ).run([.text(""), .text(xmpPath), .text(backupPath)])
    }

    public func deleteByRevision(xmpPath: String, revision: Int64) throws {
        _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ? AND revision = ?")
            .run([.text(xmpPath), .int(revision)])
    }

    public func discardModulePending(sessionId: String, sourceModule: String) throws {
        _ = try connection.prepare("""
            DELETE FROM metadata_outbox
            WHERE source_module = ?
              AND status IN ('pending', 'failed')
              AND EXISTS (
                SELECT 1 FROM metadata_outbox_sessions os
                WHERE os.xmp_path = metadata_outbox.xmp_path AND os.session_id = ?
              )
          """).run([.text(sourceModule), .text(sessionId)])
    }

    /// TS 展开 `{ ...existingPatch, ...patch }`（后者覆盖前者）。
    private func mergeObjects(_ base: JSONValue, _ overlay: JSONValue) -> JSONValue {
        guard case .object(let baseDict) = base, case .object(let overlayDict) = overlay else {
            return overlay
        }
        var merged = baseDict
        for (key, value) in overlayDict { merged[key] = value }
        return .object(merged)
    }
}
