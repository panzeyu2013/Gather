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

/// outbox 行状态：与 metadata_outbox.status 列的字符串值一一对应。
public enum OutboxStatus: String, Codable, Sendable {
    case pending
    case writing
    case written
    case failed
    case conflict
    case synced
    case clean
    case cleaned
}

/// mergeOutboxPatches 的单条输入：与 mergeOutboxPatch 的参数逐项对应。
public struct OutboxMergeRequest: Sendable {
    public let xmpPath: String
    public let sessionId: String
    public let photoPath: String
    public let patch: JSONValue
    public let dirtyFields: [String]

    public init(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) {
        self.xmpPath = xmpPath
        self.sessionId = sessionId
        self.photoPath = photoPath
        self.patch = patch
        self.dirtyFields = dirtyFields
    }
}

public protocol WritebackStore: Sendable {
    func outboxEntry(xmpPath: String) async throws -> OutboxRecord?
    func outboxEntries(sessionId: String) async throws -> [OutboxRecord]
    func outboxEntries(sessionId: String, xmpPaths: [String]) async throws -> [OutboxRecord]
    /// 无会话过滤的批量读：空参数返回 []，内部 400 分块。
    func outboxEntries(xmpPaths: [String]) async throws -> [OutboxRecord]
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
    /// 批量 merge：整个数组在单个事务内逐条执行，语义与 mergeOutboxPatch 逐字一致；空数组返回 []。
    func mergeOutboxPatches(_ requests: [OutboxMergeRequest]) async throws -> [OutboxRecord]
    func claimOutbox(xmpPath: String, expectedRevision: Int64) async throws -> Bool
    func markOutboxWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) async throws
    func markOutboxStatus(xmpPath: String, status: String, errorMessage: String) async throws
    /// CAS：仅当行 revision == expectedRevision 时更新 status/error_message；返回是否命中。
    func markOutboxStatus(
        xmpPath: String,
        expectedRevision: Int,
        status: OutboxStatus,
        errorMessage: String?
    ) async throws -> Bool
    func resetOutboxForRetry(xmpPath: String) async throws
    func setOutboxBackupPath(xmpPath: String, backupPath: String) async throws
    func initializeOutboxBaseline(xmpPath: String, baselineFingerprint: String, baselineValues: JSONValue) async throws
    /// 把 status='writing' 的残留行恢复为 'pending'，返回受影响行数。
    @discardableResult func recoverInterruptedOutbox() async throws -> Int
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

    // MARK: writeback_items

    func saveWritebackItems(sessionId: String, module: String, items: [WritebackItemInput]) async throws
    func writebackItems(sessionId: String, module: String?, status: String?) async throws -> [WritebackItemRecord]
    func writebackItem(itemId: Int64) async throws -> WritebackItemRecord?
    func updateWritebackStatus(itemId: Int64, status: String, error: String?) async throws
    func failedWritebackCount(sessionId: String, module: String?) async throws -> Int
    func deleteWritebackItems(sessionId: String, module: String?) async throws
    func deleteWritebackItems(sessionId: String, module: String, ids: [Int64]) async throws
    func updateWritebackBackupPath(itemId: Int64, path: String) async throws
    func updateWritebackAttributes(itemId: Int64, attributes: [String: JSONValue]) async throws
    func updateWritebackKeywords(itemId: Int64, keywords: [String]) async throws
    func updateWritebackAttributes(_ updates: [WritebackAttributesUpdate]) async throws
    func updateWritebackKeywords(_ updates: [WritebackKeywordsUpdate]) async throws
    func markWritebackWrittenAsSynced(sessionId: String, module: String) async throws
    func updateWritebackStatusByXmpPath(sessionId: String, module: String, xmpPath: String, status: String) async throws
    func hasActiveWriteback(xmpPath: String) async throws -> Bool
    @discardableResult func discardWritebackPending(xmpPath: String) async throws -> Int
    /// 投影单写者：单事务把 snapshot 的权威状态按 xmp_path 写入 writeback_items.xmp_status；
    /// 幂等（已是目标状态的行计 0），不触碰 attempt_count。
    @discardableResult func reconcileWritebackProjection(
        sessionId: String,
        module: String,
        snapshot: [String: OutboxStatus]
    ) async throws -> Int
    /// 裁决接受远端值：photos by filepath → photo_metadata_cache upsert → culling_decisions update
    /// → 删除该 xmpPath 的 pending writeback 行 → 删除 outbox 行；单事务整批成败，返回处理的 photos 行数。
    @discardableResult func applyAcceptedRemoteValues(
        sessionId: String,
        xmpPath: String,
        rating: Int?,
        label: String?,
        keywords: [String]?
    ) async throws -> Int
}

public extension WritebackStore {
    func markOutboxStatus(xmpPath: String, status: String) async throws {
        try await markOutboxStatus(xmpPath: xmpPath, status: status, errorMessage: "")
    }

    func writebackItems(sessionId: String) async throws -> [WritebackItemRecord] {
        try await writebackItems(sessionId: sessionId, module: nil, status: nil)
    }

    func updateWritebackStatus(itemId: Int64, status: String) async throws {
        try await updateWritebackStatus(itemId: itemId, status: status, error: nil)
    }

    func failedWritebackCount(sessionId: String) async throws -> Int {
        try await failedWritebackCount(sessionId: sessionId, module: nil)
    }

    func deleteWritebackItems(sessionId: String) async throws {
        try await deleteWritebackItems(sessionId: sessionId, module: nil)
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

    public func outboxEntries(sessionId: String, xmpPaths: [String]) async throws -> [OutboxRecord] {
        let unique = Array(Set(xmpPaths))
        guard !unique.isEmpty else { return [] }
        var rows: [OutboxRecord] = []
        for chunk in unique.chunked(by: 500) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let part = try await database.query(
                """
                SELECT o.*
                FROM metadata_outbox o
                JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
                WHERE os.session_id = ? AND o.xmp_path IN (\(placeholders))
                """,
                [.text(sessionId)] + chunk.map { .text($0) }
            ).map { try $0.decode(OutboxRecord.self) }
            rows.append(contentsOf: part)
        }
        return rows
    }

    /// 无会话过滤的批量读：按 xmpPath 去重、内部 400 分块；空参数返回 []。
    public func outboxEntries(xmpPaths: [String]) async throws -> [OutboxRecord] {
        let unique = Array(Set(xmpPaths))
        guard !unique.isEmpty else { return [] }
        var rows: [OutboxRecord] = []
        for chunk in unique.chunked(by: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let part = try await database.query(
                "SELECT * FROM metadata_outbox WHERE xmp_path IN (\(placeholders))",
                chunk.map { .text($0) }
            ).map { try $0.decode(OutboxRecord.self) }
            rows.append(contentsOf: part)
        }
        return rows.sorted { ($0.updatedAt, $0.xmpPath) < ($1.updatedAt, $1.xmpPath) }
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
            try Self.mergeOutboxPatch(
                db,
                request: OutboxMergeRequest(
                    xmpPath: xmpPath,
                    sessionId: sessionId,
                    photoPath: photoPath,
                    patch: patch,
                    dirtyFields: dirtyFields
                )
            )
        }
    }

    /// 批量版本：全部请求在同一个事务内逐条合并，任一条失败整批回滚；返回顺序与入参一致。
    public func mergeOutboxPatches(_ requests: [OutboxMergeRequest]) async throws -> [OutboxRecord] {
        guard !requests.isEmpty else { return [] }
        return try await database.transaction { db in
            try requests.map { try Self.mergeOutboxPatch(db, request: $0) }
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

    /// CAS 状态迁移：revision 不匹配时受影响行数为 0，DB 不变并返回 false。
    @discardableResult
    public func markOutboxStatus(
        xmpPath: String,
        expectedRevision: Int,
        status: OutboxStatus,
        errorMessage: String? = nil
    ) async throws -> Bool {
        let affected = try await database.run(
            "UPDATE metadata_outbox SET status = ?, error_message = ?, updated_at = ? WHERE xmp_path = ? AND revision = ?",
            [
                .text(status.rawValue), .text(errorMessage ?? ""), .text(nowISOString()),
                .text(xmpPath), .int(Int64(expectedRevision)),
            ]
        )
        return affected > 0
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

    @discardableResult
    public func recoverInterruptedOutbox() async throws -> Int {
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

    /// 单条读-改-写：必须由调用方放进事务（无 await），mergeOutboxPatch / mergeOutboxPatches 共用。
    private static func mergeOutboxPatch(
        _ db: isolated SQLiteDatabase,
        request: OutboxMergeRequest
    ) throws -> OutboxRecord {
        let existing = try outboxEntry(db, xmpPath: request.xmpPath)
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
        let mergedPatch = mergeObjects(existingPatch, request.patch)
        var mergedDirty: [String] = []
        for field in existingDirty + request.dirtyFields where !mergedDirty.contains(field) {
            mergedDirty.append(field)
        }
        let sourceModule = request.patch["source"]?.stringValue ?? ""
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
                .text(request.xmpPath), .text(request.sessionId), .text(request.sessionId), .text(request.photoPath),
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
            [.text(request.xmpPath), .text(request.sessionId), .text(now)]
        )
        try db.run("UPDATE metadata_outbox_sessions SET confirmed_at = '' WHERE xmp_path = ?", [.text(request.xmpPath)])
        guard let record = try outboxEntry(db, xmpPath: request.xmpPath) else {
            throw SQLiteFailure(
                phase: .other, code: 0, extended: 0,
                message: "outbox row missing after merge: \(request.xmpPath)"
            )
        }
        return record
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

// MARK: - writeback_items

/// saveWritebackItems 的单条输入（attributes 用 JSONValue 替代旧 [String: Any]，
// 保持 Sendable 且序列化语义一致）。
public struct WritebackItemInput: Sendable {
    public let photoId: String
    public let photoPath: String
    public let module: String
    public let keywords: [String]
    public let attributes: [String: JSONValue]?
    public let xmpPath: String
    public let backupPath: String

    public init(
        photoId: String,
        photoPath: String,
        module: String,
        keywords: [String],
        attributes: [String: JSONValue]? = nil,
        xmpPath: String,
        backupPath: String
    ) {
        self.photoId = photoId
        self.photoPath = photoPath
        self.module = module
        self.keywords = keywords
        self.attributes = attributes
        self.xmpPath = xmpPath
        self.backupPath = backupPath
    }
}

public struct WritebackAttributesUpdate: Sendable {
    public let id: Int64
    public let attributes: [String: JSONValue]

    public init(id: Int64, attributes: [String: JSONValue]) {
        self.id = id
        self.attributes = attributes
    }
}

public struct WritebackKeywordsUpdate: Sendable {
    public let id: Int64
    public let keywords: [String]

    public init(id: Int64, keywords: [String]) {
        self.id = id
        self.keywords = keywords
    }
}

public struct WritebackItemRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let photoId: String
    public let photoPath: String
    public let sessionId: String
    public let module: String
    public let keywords: String
    public let attributesJson: String
    public let xmpPath: String
    public let backupPath: String
    public let xmpStatus: String
    public let errorMessage: String
    public let attemptCount: Int
    public let lastAttemptAt: String

    /// attributes_json → JSONValue（损坏数据返回 nil）。
    public var attributes: JSONValue? {
        try? JSONValue.parse(attributesJson)
    }

    /// keywords JSON → 字符串数组（损坏数据返回空数组）。
    public var keywordList: [String] {
        ((try? JSONValue.parse(keywords)) as JSONValue?)?.arrayValue ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, module, keywords
        case photoId = "photo_id"
        case photoPath = "photo_path"
        case sessionId = "session_id"
        case attributesJson = "attributes_json"
        case xmpPath = "xmp_path"
        case backupPath = "backup_path"
        case xmpStatus = "xmp_status"
        case errorMessage = "error_message"
        case attemptCount = "attempt_count"
        case lastAttemptAt = "last_attempt_at"
    }
}

public extension SQLiteWritebackStore {
    /// 先删掉该 (session, module) 下 pending/failed 的旧行，再批量插入。
    func saveWritebackItems(sessionId: String, module: String, items: [WritebackItemInput]) async throws {
        let now = nowISOString()
        try await database.transaction { db in
            try db.run(
                "DELETE FROM writeback_items WHERE session_id = ? AND module = ? AND xmp_status IN ('pending', 'failed')",
                [.text(sessionId), .text(module)]
            )
            for item in items {
                try db.run(
                    """
                    INSERT INTO writeback_items
                      (photo_id, photo_path, session_id, module, keywords, attributes_json,
                       xmp_path, backup_path, xmp_status, error_message, last_attempt_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?)
                    """,
                    [
                        .text(item.photoId),
                        .text(item.photoPath),
                        .text(sessionId),
                        .text(module),
                        .text(Self.keywordsJSON(item.keywords)),
                        .text(Self.attributesJSON(item.attributes ?? [:])),
                        .text(item.xmpPath),
                        .text(item.backupPath),
                        .text(now),
                    ]
                )
            }
        }
    }

    func writebackItems(sessionId: String, module: String? = nil, status: String? = nil) async throws -> [WritebackItemRecord] {
        var sql = "SELECT * FROM writeback_items WHERE session_id = ?"
        var values: [SQLiteValue] = [.text(sessionId)]
        if let module, !module.isEmpty {
            sql += " AND module = ?"
            values.append(.text(module))
        }
        if let status, !status.isEmpty {
            sql += " AND xmp_status = ?"
            values.append(.text(status))
        }
        sql += " ORDER BY id ASC"
        return try await database.query(sql, values).map { try $0.decode(WritebackItemRecord.self) }
    }

    func writebackItem(itemId: Int64) async throws -> WritebackItemRecord? {
        try await database.queryOne("SELECT * FROM writeback_items WHERE id = ?", [.int(itemId)])?
            .decode(WritebackItemRecord.self)
    }

    func updateWritebackStatus(itemId: Int64, status: String, error: String? = nil) async throws {
        try await database.run(
            """
            UPDATE writeback_items
            SET xmp_status = ?, error_message = ?, attempt_count = attempt_count + 1, last_attempt_at = ?
            WHERE id = ?
            """,
            [.text(status), .text(error ?? ""), .text(nowISOString()), .int(itemId)]
        )
    }

    func failedWritebackCount(sessionId: String, module: String? = nil) async throws -> Int {
        var sql = "SELECT COUNT(*) AS count FROM writeback_items WHERE session_id = ? AND xmp_status = ?"
        var values: [SQLiteValue] = [.text(sessionId), .text("failed")]
        if let module, !module.isEmpty {
            sql += " AND module = ?"
            values.append(.text(module))
        }
        return Int(try await database.scalarInt(sql, values) ?? 0)
    }

    func deleteWritebackItems(sessionId: String, module: String? = nil) async throws {
        if let module, !module.isEmpty {
            try await database.run(
                "DELETE FROM writeback_items WHERE session_id = ? AND module = ?",
                [.text(sessionId), .text(module)]
            )
            return
        }
        try await database.run("DELETE FROM writeback_items WHERE session_id = ?", [.text(sessionId)])
    }

    /// 只删除指定 (session, module) 下状态为 synced 且 id 在列表中的行（400 分块）。
    func deleteWritebackItems(sessionId: String, module: String, ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        var doomed: [Int64] = []
        for chunk in ids.chunked(by: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT id FROM writeback_items
                WHERE session_id = ? AND module = ? AND xmp_status = 'synced' AND id IN (\(placeholders))
                """,
                [.text(sessionId), .text(module)] + chunk.map { .int($0) }
            )
            doomed.append(contentsOf: rows.compactMap { $0.int("id") })
        }
        for chunk in doomed.chunked(by: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            try await database.run(
                "DELETE FROM writeback_items WHERE id IN (\(placeholders))",
                chunk.map { .int($0) }
            )
        }
    }

    func updateWritebackBackupPath(itemId: Int64, path: String) async throws {
        try await database.run(
            "UPDATE writeback_items SET backup_path = ? WHERE id = ?",
            [.text(path), .int(itemId)]
        )
    }

    func updateWritebackAttributes(itemId: Int64, attributes: [String: JSONValue]) async throws {
        try await database.run(
            "UPDATE writeback_items SET attributes_json = ? WHERE id = ?",
            [.text(Self.attributesJSON(attributes)), .int(itemId)]
        )
    }

    func updateWritebackKeywords(itemId: Int64, keywords: [String]) async throws {
        try await database.run(
            "UPDATE writeback_items SET keywords = ? WHERE id = ?",
            [.text(Self.keywordsJSON(keywords)), .int(itemId)]
        )
    }

    func updateWritebackAttributes(_ updates: [WritebackAttributesUpdate]) async throws {
        guard !updates.isEmpty else { return }
        try await database.transaction { db in
            for update in updates {
                try db.run(
                    "UPDATE writeback_items SET attributes_json = ? WHERE id = ?",
                    [.text(Self.attributesJSON(update.attributes)), .int(update.id)]
                )
            }
        }
    }

    func updateWritebackKeywords(_ updates: [WritebackKeywordsUpdate]) async throws {
        guard !updates.isEmpty else { return }
        try await database.transaction { db in
            for update in updates {
                try db.run(
                    "UPDATE writeback_items SET keywords = ? WHERE id = ?",
                    [.text(Self.keywordsJSON(update.keywords)), .int(update.id)]
                )
            }
        }
    }

    func markWritebackWrittenAsSynced(sessionId: String, module: String) async throws {
        try await database.run(
            "UPDATE writeback_items SET xmp_status = 'synced' WHERE session_id = ? AND module = ? AND xmp_status = 'written'",
            [.text(sessionId), .text(module)]
        )
    }

    func updateWritebackStatusByXmpPath(
        sessionId: String,
        module: String,
        xmpPath: String,
        status: String
    ) async throws {
        try await database.run(
            """
            UPDATE writeback_items SET xmp_status = ?, error_message = ''
            WHERE session_id = ? AND module = ? AND xmp_path = ?
            """,
            [.text(status), .text(sessionId), .text(module), .text(xmpPath)]
        )
    }

    func hasActiveWriteback(xmpPath: String) async throws -> Bool {
        try await database.queryOne(
            "SELECT 1 FROM writeback_items WHERE xmp_path = ? AND xmp_status IN ('pending', 'writing', 'written', 'synced') LIMIT 1",
            [.text(xmpPath)]
        ) != nil
    }

    /// 返回删除行数（TS: run(...).changes）。
    @discardableResult
    func discardWritebackPending(xmpPath: String) async throws -> Int {
        try await database.run(
            "DELETE FROM writeback_items WHERE xmp_path = ? AND xmp_status IN ('pending', 'failed')",
            [.text(xmpPath)]
        )
    }

    /// 投影单写者：单事务、幂等。只按 xmp_path 写 xmp_status，不触碰 attempt_count/error_message；
    /// 已是目标状态的行计 0，因此重复调用返回 0 且 DB 不变。
    @discardableResult
    func reconcileWritebackProjection(
        sessionId: String,
        module: String,
        snapshot: [String: OutboxStatus]
    ) async throws -> Int {
        guard !snapshot.isEmpty else { return 0 }
        return try await database.transaction { db in
            var updated = 0
            for (xmpPath, status) in snapshot {
                updated += try db.run(
                    """
                    UPDATE writeback_items SET xmp_status = ?
                    WHERE session_id = ? AND module = ? AND xmp_path = ? AND xmp_status != ?
                    """,
                    [
                        .text(status.rawValue), .text(sessionId), .text(module),
                        .text(xmpPath), .text(status.rawValue),
                    ]
                )
            }
            return updated
        }
    }

    /// 裁决接受远端值：photos by filepath → photo_metadata_cache upsert → culling_decisions update
    /// → 删除该 xmpPath 的 pending writeback 行 → 删除 outbox 行。
    /// 单事务：任一步抛错整批回滚。nil 字段表示未被接受，保持缓存/决策原值。
    /// 返回按 filepath 匹配处理的 photos 行数（无匹配时仍执行清理，返回 0）。
    @discardableResult
    func applyAcceptedRemoteValues(
        sessionId: String,
        xmpPath: String,
        rating: Int?,
        label: String?,
        keywords: [String]?
    ) async throws -> Int {
        let keywordsValue: SQLiteValue = keywords.map {
            .text((try? JSONValue.stringify(JSONValue.array($0.map { JSONValue.string($0) }))) ?? "[]")
        } ?? .null
        let ratingValue: SQLiteValue = rating.map { .int(Int64($0)) } ?? .null
        let labelValue: SQLiteValue = label.map { .text($0) } ?? .null
        let now = nowISOString()
        return try await database.transaction { db in
            // 1) photo_path 以 outbox 权威行为准，缺失时回退 writeback_items 投影。
            let outboxPath = try db.queryOne(
                "SELECT photo_path FROM metadata_outbox WHERE xmp_path = ?",
                [.text(xmpPath)]
            )?.text("photo_path") ?? ""
            let resolvedPath: String
            if !outboxPath.isEmpty {
                resolvedPath = outboxPath
            } else {
                resolvedPath = try db.queryOne(
                    """
                    SELECT photo_path FROM writeback_items
                    WHERE session_id = ? AND xmp_path = ? AND photo_path != ''
                    LIMIT 1
                    """,
                    [.text(sessionId), .text(xmpPath)]
                )?.text("photo_path") ?? ""
            }
            // 2) photos by filepath（限定会话）。
            let photoIds: [String]
            if resolvedPath.isEmpty {
                photoIds = []
            } else {
                photoIds = try db.query(
                    "SELECT id FROM photos WHERE session_id = ? AND filepath = ?",
                    [.text(sessionId), .text(resolvedPath)]
                ).compactMap { $0.text("id") }
            }
            // 3) 缓存 upsert + 决策更新。
            for photoId in photoIds {
                try db.run(
                    """
                    INSERT INTO photo_metadata_cache (photo_id, session_id, keywords, rating, label, cached_at)
                    VALUES (?, ?, COALESCE(?, '[]'), COALESCE(?, 0), ?, ?)
                    ON CONFLICT(photo_id) DO UPDATE SET
                      keywords = COALESCE(?, photo_metadata_cache.keywords),
                      rating = COALESCE(?, photo_metadata_cache.rating),
                      label = COALESCE(?, photo_metadata_cache.label),
                      cached_at = excluded.cached_at
                    """,
                    [
                        .text(photoId), .text(sessionId), keywordsValue, ratingValue, labelValue, .text(now),
                        keywordsValue, ratingValue, labelValue,
                    ]
                )
                try db.run(
                    """
                    UPDATE culling_decisions
                    SET rating = COALESCE(?, rating),
                        color_label = COALESCE(?, color_label),
                        updated_at = ?
                    WHERE photo_id = ? AND session_id = ?
                    """,
                    [ratingValue, labelValue, .text(now), .text(photoId), .text(sessionId)]
                )
            }
            // 4) 清理：pending/failed 投影行 + 权威 outbox 行（sessions 边由 CASCADE 删除）。
            try db.run(
                "DELETE FROM writeback_items WHERE xmp_path = ? AND xmp_status IN ('pending', 'failed')",
                [.text(xmpPath)]
            )
            try db.run("DELETE FROM metadata_outbox WHERE xmp_path = ?", [.text(xmpPath)])
            return photoIds.count
        }
    }

    private static func keywordsJSON(_ keywords: [String]) -> String {
        (try? JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))) ?? "[]"
    }

    private static func attributesJSON(_ attributes: [String: JSONValue]) -> String {
        (try? JSONValue.stringify(JSONValue.object(attributes))) ?? "{}"
    }
}
