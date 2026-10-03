// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/MetadataOutboxRepo.swift
// metadata_outbox 仓库 —— 写回状态机的唯一持久真相源（R4 重写）。
//
// 设计要点（全部为"构造上不可能出错"，不是调用方约定）：
// 1. 显式状态机 MetadataOutboxStatus + 迁移表；所有写状态的操作都经 transition()，
//    非法迁移抛 MetadataOutboxError.illegalTransition（不再有"随手写个字符串状态"）。
// 2. writing 是租约态而非终态：claim 时写 updated_at 作为租约起点；recoverInterrupted
//    在进程启动时清空全部 writing（新进程不可能持有租约）；recoverExpiredLeases 在运行
//    期把超过租约窗口、且不在本进程 activePaths 里的 writing 行归位（重试或 failed+原因）。
//    => writing 永远有出口。
// 3. 路径口径唯一：MetadataOutboxPath.sidecar(photoPath) = TSPath.xmpSidecarPath(
//    ScanPath.canonical(photoPath))，仓库内每个入口都对 xmpPath 归一化（幂等）。
// 4. 字段级归属：patch_json.__owners__ 记录每个字段由哪个模块引入；跨模块 discard 只删
//    本模块拥有的字段，其余字段与整行生命周期不受影响。
// 5. 字段级合并：后者覆盖前者的同名字段，未提及的字段原样保留（rating/label/keywords 不丢）。

import Foundation

/// outbox 行的合法状态。
public enum MetadataOutboxStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case writing
    case written
    case synced
    case failed
    case conflict
    /// 历史版本的终态（Schema 的 CHECK 允许 'clean'/'cleaned'，当前代码不再产生）。
    /// 只允许归一为 synced —— 否则这类行既不计 pending、不进恢复、cleanup 又必抛。
    case clean
    case cleaned

    /// 合法迁移表（唯一真相源）。删除行（cleanup/finalize/discard）不在此表内。
    ///
    /// 少数写入是**原子 CAS**（带 WHERE 条件与 revision 守卫，无法拆成 get+update），
    /// 其状态列与下表逐项一致，逐条清单：
    /// - claim(pending|failed → writing)、markWritten(writing → written|pending)、
    ///   markConflict(… → conflict，先经 canTransition)、markFailed(… → failed)、
    ///   markSessionSynced(written → synced，要求所有关联会话已确认)、
    ///   mergePatch(conflict→conflict、writing→writing，其余→pending 含 synced→pending)。
    /// 其余状态写入（resetForRetry / recoverInterrupted / recoverExpiredLeases /
    /// discardModulePending / transition 本身）全部经 transition()。
    public func canTransition(to next: MetadataOutboxStatus) -> Bool {
        switch (self, next) {
        case (.pending, .writing), (.pending, .pending), (.pending, .conflict), (.pending, .failed),
             (.writing, .writing), (.writing, .written), (.writing, .failed), (.writing, .conflict),
             (.writing, .pending),
             (.failed, .writing), (.failed, .pending), (.failed, .failed), (.failed, .conflict),
             (.written, .synced), (.written, .pending), (.written, .conflict), (.written, .written),
             (.synced, .conflict), (.synced, .synced),
             (.conflict, .pending), (.conflict, .writing), (.conflict, .conflict),
             // 已确认的行被新变更重新打开（mergePatch 的合法迁移）。
             (.synced, .pending),
             (.clean, .synced), (.clean, .clean),
             (.cleaned, .synced), (.cleaned, .cleaned):
            return true
        default:
            return false
        }
    }
}

public enum MetadataOutboxError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case illegalTransition(xmpPath: String, from: String, to: String)
    case rowNotFound(xmpPath: String)
    case corruptOwners(xmpPath: String)

    public var code: String {
        switch self {
        case .illegalTransition: "XMP_OUTBOX_ILLEGAL_TRANSITION"
        case .rowNotFound: "XMP_OUTBOX_NOT_FOUND"
        case .corruptOwners: "XMP_OUTBOX_CORRUPT_OWNERS"
        }
    }

    public var description: String {
        switch self {
        case .illegalTransition(let path, let from, let to):
            "XMP_OUTBOX_ILLEGAL_TRANSITION: " + path + " " + from + " -> " + to
        case .rowNotFound(let path):
            "XMP_OUTBOX_NOT_FOUND: " + path
        case .corruptOwners(let path):
            "XMP_OUTBOX_CORRUPT_OWNERS: " + path
        }
    }

    public var errorDescription: String? { description }
}

/// 路径口径唯一来源：photo 路径 → 侧车路径。
public enum MetadataOutboxPath {
    /// TSPath.xmpSidecarPath + ScanPath.canonical。对已经是侧车路径的输入幂等。
    public static func sidecar(_ photoPath: String) -> String {
        TSPath.xmpSidecarPath(ScanPath.canonical(photoPath))
    }

    /// 归一化任意路径为侧车键（入参可能是照片或侧车路径）。
    public static func normalize(_ path: String) -> String {
        sidecar(path)
    }
}

/// patch_json 里保留的字段名（不是用户字段）。
private enum OutboxPatchKey {
    static let owners = "__owners__"
    /// 进入 conflict 时落盘的远程值快照（裁决不再依赖二次读盘）。
    static let remote = "__remote__"
    static let source = "source"
    static let reserved: Set<String> = [owners, remote, source]
}

/// metadata_outbox 表行（列序与 SELECT * 一致，见 Schema.swift）。
/// Swift 6：该行会进入 batchAsync 的并发 worker（T: Sendable 约束），
/// 全字段均为不可变值类型，补上 Sendable 是纯增量的编译期事实。
public struct MetadataOutboxRow: Sendable {
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

    public var typedStatus: MetadataOutboxStatus? { MetadataOutboxStatus(rawValue: status) }

    public var patch: JSONValue {
        (try? JSONValue.parse(patchJSON)) ?? JSONValue.object([:])
    }

    public var dirty: [String] {
        ((try? JSONValue.parse(dirtyFields)) as JSONValue?)?.arrayValue ?? []
    }

    /// 字段 → 引入模块（缺失键表示"未记录"，回退 source_module）。
    public var fieldOwners: [String: String] {
        guard case .object(let dict) = patch,
              case .object(let owners)? = dict[OutboxPatchKey.owners] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in owners where value.stringValue != nil {
            result[key] = value.stringValue
        }
        return result
    }

    /// 纯业务字段（去掉保留键）。
    public var fieldsPatch: [String: JSONValue] {
        guard case .object(let dict) = patch else { return [:] }
        return dict.filter { !OutboxPatchKey.reserved.contains($0.key) }
    }

    /// conflict 行落盘的远程值快照（无则 nil）。
    public var remoteSnapshot: JSONValue? {
        guard case .object(let dict) = patch else { return nil }
        return dict[OutboxPatchKey.remote]
    }

    /// 行在给定模块下的可见性：任一字段由该模块拥有，或整行 source_module 命中。
    public func isOwned(byModule module: String) -> Bool {
        let owners = fieldOwners
        if owners.isEmpty { return sourceModule == module }
        return owners.values.contains(module)
    }
}

/// 摘要投影（SummaryRow）：供 summary push 使用，不含重型 JSON 列。
/// Swift 6：全字段不可变值类型，随 MetadataOutboxRow 一并标 Sendable。
public struct MetadataOutboxSummaryRow: Sendable {
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

/// 租约恢复结果。
public struct MetadataOutboxLeaseRecovery: Equatable, Sendable {
    public let xmpPath: String
    public let newStatus: MetadataOutboxStatus
    public let reason: String

    public init(xmpPath: String, newStatus: MetadataOutboxStatus, reason: String) {
        self.xmpPath = xmpPath
        self.newStatus = newStatus
        self.reason = reason
    }
}

/// metadata_outbox 仓库。所有状态写入都经 transition()（唯一状态机入口）。
public final class MetadataOutboxRepo: Sendable {
    private let connection: DBConnection
    /// 租约窗口：超过该时长的 writing 行可被安全重新 claim（崩溃/挂死恢复）。
    public static let defaultLeaseMs = 120_000

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 查询

    public func get(_ xmpPath: String) throws -> MetadataOutboxRow? {
        guard let row = try connection.prepare("SELECT * FROM metadata_outbox WHERE xmp_path = ?")
            .get([.text(MetadataOutboxPath.normalize(xmpPath))]) else { return nil }
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
          """).query([.text(MetadataOutboxPath.normalize(xmpPath))])
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
        let rows = try connection.prepare("""
            SELECT o.*
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
              AND o.status IN ('written', 'synced')
          """).query([.text(sessionId)])
        for row in rows.map({ MetadataOutboxRow(row: $0) }) {
            let owners = row.fieldOwners
            let modules = owners.isEmpty ? [row.sourceModule] : Array(Set(owners.values))
            for candidate in modules where candidate != module
                && ["face-keyword", "similarity", "template"].contains(candidate) {
                return true
            }
        }
        return false
    }

    public func getRecoverableActive() throws -> [MetadataOutboxRow] {
        let rows = try connection.prepare("""
            SELECT * FROM metadata_outbox
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

    // MARK: - 状态机（唯一入口）

    /// 合法迁移；非法迁移抛 MetadataOutboxError.illegalTransition。
    @discardableResult
    public func transition(
        xmpPath: String,
        from expected: [MetadataOutboxStatus],
        to next: MetadataOutboxStatus,
        errorMessage: String? = nil,
        resetAttempts: Bool = false
    ) throws -> MetadataOutboxRow {
        let path = MetadataOutboxPath.normalize(xmpPath)
        guard let current = try get(path) else { throw MetadataOutboxError.rowNotFound(xmpPath: path) }
        guard let typed = current.typedStatus else {
            throw MetadataOutboxError.illegalTransition(xmpPath: path, from: current.status, to: next.rawValue)
        }
        guard expected.contains(typed) else {
            throw MetadataOutboxError.illegalTransition(xmpPath: path, from: typed.rawValue, to: next.rawValue)
        }
        guard typed.canTransition(to: next) else {
            throw MetadataOutboxError.illegalTransition(xmpPath: path, from: typed.rawValue, to: next.rawValue)
        }
        var sql = "UPDATE metadata_outbox SET status = ?, updated_at = ?"
        var values: [DBValue?] = [.text(next.rawValue), .text(nowISOString())]
        if let errorMessage {
            sql += ", error_message = ?"
            values.append(.text(errorMessage))
        }
        if resetAttempts {
            sql += ", attempt_count = 0"
        }
        sql += " WHERE xmp_path = ? AND status = ?"
        values.append(.text(path))
        values.append(.text(typed.rawValue))
        let changed = try connection.prepare(sql).run(values)
        guard changed >= 1, let updated = try get(path) else {
            throw MetadataOutboxError.illegalTransition(xmpPath: path, from: typed.rawValue, to: next.rawValue)
        }
        return updated
    }

    // MARK: - 入队（字段级合并 + 归属）

    public func mergePatch(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) throws -> MetadataOutboxRow {
        let path = MetadataOutboxPath.normalize(xmpPath)
        let canonicalPhotoPath = ScanPath.canonical(photoPath)
        try connection.transaction {
            let existing = try get(path)
            let incoming: [String: JSONValue] = {
                guard case .object(let dict) = patch else { return [:] }
                return dict
            }()
            let incomingSource = incoming[OutboxPatchKey.source]?.stringValue ?? ""
            let resolvedSource = incomingSource.isEmpty ? "manual" : incomingSource

            var mergedFields: [String: JSONValue] = [:]
            var mergedDirty: [String] = []
            var owners: [String: String] = [:]
            var revision: Int64 = 1

            var carriedRemote: JSONValue?
            if let existing {
                let keepsPatch = !(existing.persistedRevision == existing.revision
                    && ["written", "synced"].contains(existing.status))
                if keepsPatch {
                    mergedFields = existing.fieldsPatch
                    mergedDirty = existing.dirty
                    owners = existing.fieldOwners
                }
                if existing.typedStatus == .conflict {
                    // 冲突未裁决：远程快照随行保留（裁决不依赖二次读盘）。
                    carriedRemote = existing.remoteSnapshot
                }
                revision = existing.revision + 1
            }
            // 后者覆盖前者（同名字段）；未提及字段原样保留。
            for (key, value) in incoming where !OutboxPatchKey.reserved.contains(key) {
                mergedFields[key] = value
            }
            for field in dirtyFields where !mergedDirty.contains(field) {
                mergedDirty.append(field)
            }
            for field in incoming.keys where !OutboxPatchKey.reserved.contains(field) {
                owners[field] = resolvedSource
            }
            for field in dirtyFields {
                owners[field] = resolvedSource
            }
            mergedDirty = mergedDirty.filter { mergedFields[$0] != nil }

            var envelope = mergedFields
            if !owners.isEmpty {
                envelope[OutboxPatchKey.owners] = .object(owners.mapValues { .string($0) })
            }
            if let carriedRemote {
                envelope[OutboxPatchKey.remote] = carriedRemote
            }
            envelope[OutboxPatchKey.source] = .string(resolvedSource)
            let now = nowISOString()

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
                status = CASE
                  WHEN metadata_outbox.status = 'conflict' THEN 'conflict'
                  WHEN metadata_outbox.status = 'writing' THEN 'writing'
                  ELSE 'pending' END,
                attempt_count = 0,
                error_message = CASE WHEN metadata_outbox.status = 'conflict'
                                     THEN metadata_outbox.error_message ELSE '' END,
                updated_at = excluded.updated_at
              """).run([
                .text(path),
                .text(sessionId),
                .text(sessionId),
                .text(canonicalPhotoPath),
                .text(try JSONValue.stringify(.object(envelope))),
                .text(try JSONValue.stringify(.array(mergedDirty.map { JSONValue.string($0) }))),
                .text(resolvedSource),
                .int(revision),
                .text(now),
            ])
            _ = try connection.prepare("""
                INSERT INTO metadata_outbox_sessions
                  (xmp_path, session_id, confirmed_at, linked_at)
                VALUES (?, ?, '', ?)
                ON CONFLICT(xmp_path, session_id) DO UPDATE SET confirmed_at = ''
              """).run([.text(path), .text(sessionId), .text(now)])
            _ = try connection.prepare("""
                UPDATE metadata_outbox_sessions SET confirmed_at = '' WHERE xmp_path = ?
              """).run([.text(path)])
        }
        guard let row = try get(path) else { throw MetadataOutboxError.rowNotFound(xmpPath: path) }
        return row
    }

    /// 丢弃 (session, module) 拥有的字段；行上仍有其它模块字段时保留整行。
    /// 返回 (删除的行数, 保留但被裁剪的行数)。
    @discardableResult
    public func discardModulePending(sessionId: String, sourceModule: String) throws -> (deleted: Int, trimmed: Int) {
        var deleted = 0
        var trimmed = 0
        try connection.transaction {
            let rows = try getBySession(sessionId).filter {
                $0.status == "pending" || $0.status == "failed"
            }
            for row in rows {
                let owners = row.fieldOwners
                var fields = row.fieldsPatch
                var dirty = row.dirty
                var remainingOwners = owners
                var removedAny = false
                // 无字段的行（例如只带 source 的预约行）：整行归 source_module。
                if dirty.isEmpty {
                    let rowOwner = owners.values.first ?? row.sourceModule
                    if rowOwner == sourceModule {
                        _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ?")
                            .run([.text(row.xmpPath)])
                        _ = try connection.prepare("DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?")
                            .run([.text(row.xmpPath)])
                        deleted += 1
                    }
                    continue
                }
                for field in dirty {
                    let owner = owners[field] ?? row.sourceModule
                    if owner == sourceModule {
                        fields.removeValue(forKey: field)
                        remainingOwners.removeValue(forKey: field)
                        dirty.removeAll { $0 == field }
                        removedAny = true
                    }
                }
                guard removedAny else { continue }
                if fields.isEmpty {
                    _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ?")
                        .run([.text(row.xmpPath)])
                    _ = try connection.prepare("DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?")
                        .run([.text(row.xmpPath)])
                    deleted += 1
                    continue
                }
                var envelope = fields
                if !remainingOwners.isEmpty {
                    envelope[OutboxPatchKey.owners] = .object(remainingOwners.mapValues { .string($0) })
                }
                _ = try connection.prepare("""
                    UPDATE metadata_outbox
                    SET patch_json = ?, dirty_fields = ?, revision = revision + 1,
                        attempt_count = 0, error_message = '', updated_at = ?
                    WHERE xmp_path = ?
                  """).run([
                    .text(try JSONValue.stringify(.object(envelope))),
                    .text(try JSONValue.stringify(.array(dirty.map { JSONValue.string($0) }))),
                    .text(nowISOString()),
                    .text(row.xmpPath),
                  ])
                // 状态迁移仍走唯一迁移表（pending/failed → pending）。
                _ = try transition(xmpPath: row.xmpPath, from: [.pending, .failed], to: .pending)
                trimmed += 1
            }
        }
        return (deleted, trimmed)
    }

    // MARK: - 写入生命周期

    /// pending/failed → writing（租约起点 = updated_at）。返回是否真的抢到该 revision。
    public func claim(xmpPath: String, expectedRevision: Int64) throws -> Bool {
        let changed = try connection.prepare("""
            UPDATE metadata_outbox
            SET status = 'writing',
                attempt_count = attempt_count + 1,
                updated_at = ?
            WHERE xmp_path = ?
              AND revision = ?
              AND status IN ('pending', 'failed')
          """).run([.text(nowISOString()), .text(MetadataOutboxPath.normalize(xmpPath)), .int(expectedRevision)])
        return changed == 1
    }

    /// writing → written（revision 守卫：旧 revision 落盘后行保持 pending）。
    /// 返回值语义：**写到盘的这次写入是否被记账**（persisted_revision/基线/备份落库成功）。
    /// - true：本次写入已记账；若期间来了新 revision，行回到 pending（返回值不表示"已终态"）。
    /// - false：行已不在 writing（被丢弃/被清理）→ 本次写入未记账，调用方不得谎报成功。
    @discardableResult
    public func markWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) throws -> Bool {
        let path = MetadataOutboxPath.normalize(xmpPath)
        let changed = try connection.prepare("""
            UPDATE metadata_outbox
            SET persisted_revision = ?,
                base_fingerprint = ?,
                base_values_json = ?,
                backup_path = ?,
                status = CASE WHEN revision = ? THEN 'written' ELSE 'pending' END,
                error_message = '',
                updated_at = ?
            WHERE xmp_path = ? AND status = 'writing'
          """).run([
            .int(revision),
            .text(fingerprint),
            .text(try JSONValue.stringify(baseValues)),
            .text(backupPath),
            .int(revision),
            .text(nowISOString()),
            .text(path),
          ])
        return changed == 1
    }

    /// 外部修改冲突：pending/writing/written/synced → conflict，并落盘远程值快照。
    /// 此后裁决只依赖行内数据（dirty_fields/local patch/remote snapshot），文件不可读也能结清。
    @discardableResult
    public func markConflict(xmpPath: String, remote: JSONValue, reason: String) throws -> MetadataOutboxRow {
        let path = MetadataOutboxPath.normalize(xmpPath)
        guard let current = try get(path) else { throw MetadataOutboxError.rowNotFound(xmpPath: path) }
        guard let typed = current.typedStatus, typed.canTransition(to: .conflict) else {
            throw MetadataOutboxError.illegalTransition(
                xmpPath: path, from: current.status, to: MetadataOutboxStatus.conflict.rawValue)
        }
        var envelope = current.fieldsPatch
        envelope[OutboxPatchKey.remote] = remote
        if !current.fieldOwners.isEmpty {
            envelope[OutboxPatchKey.owners] = .object(current.fieldOwners.mapValues { .string($0) })
        }
        envelope[OutboxPatchKey.source] = .string(current.sourceModule)
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET status = 'conflict', error_message = ?, patch_json = ?, updated_at = ?
            WHERE xmp_path = ? AND status = ?
          """).run([
            .text(reason),
            .text(try JSONValue.stringify(.object(envelope))),
            .text(nowISOString()),
            .text(path),
            .text(typed.rawValue),
          ])
        guard let updated = try get(path) else { throw MetadataOutboxError.rowNotFound(xmpPath: path) }
        return updated
    }

    /// 写入失败：writing/pending/failed → failed（携带类型化原因）。
    @discardableResult
    public func markFailed(xmpPath: String, reason: String) throws -> MetadataOutboxRow {
        let path = MetadataOutboxPath.normalize(xmpPath)
        let now = nowISOString()
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET status = 'failed', error_message = ?, updated_at = ?
            WHERE xmp_path = ? AND status IN ('writing', 'pending', 'failed')
          """).run([.text(reason), .text(now), .text(path)])
        guard let row = try get(path) else { throw MetadataOutboxError.rowNotFound(xmpPath: path) }
        return row
    }

    /// 清除失败标记重新入队：failed → pending（重试语义）。
    /// 与其余状态写入一样经 transition（唯一迁移表），非法态不会被静默改写。
    public func resetForRetry(_ xmpPath: String) throws {
        _ = try transition(xmpPath: xmpPath, from: [.failed], to: .pending, errorMessage: "", resetAttempts: true)
    }

    public func setBackupPath(xmpPath: String, backupPath: String) throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET backup_path = ?, updated_at = ?
            WHERE xmp_path = ? AND backup_path = ''
          """).run([.text(backupPath), .text(nowISOString()), .text(MetadataOutboxPath.normalize(xmpPath))])
    }

    /// 单飞基线：仅当尚无基线时写入（不覆盖已有基线）。
    public func initializeBaseline(xmpPath: String, baselineFingerprint: String, baselineValues: JSONValue) throws {
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET base_fingerprint = ?, base_values_json = ?, updated_at = ?
            WHERE xmp_path = ? AND base_fingerprint = ''
          """).run([
            .text(baselineFingerprint),
            .text(try JSONValue.stringify(baselineValues)),
            .text(nowISOString()),
            .text(MetadataOutboxPath.normalize(xmpPath)),
          ])
    }

    // MARK: - 租约恢复（writing 永远有出口）

    /// 进程启动恢复：新进程不可能持有任何租约 → 全部 writing 归位为 pending。
    /// 同时归一遗留状态：历史版本写入过 CHECK 允许但枚举不认识的 'clean'/'cleaned'
    /// （既不计 pending、不进恢复、cleanup 又必抛）→ 统一映射为终态 synced，
    /// 使其回到正常出口（confirm 后的 cleanup/finalize 可处理）。
    @discardableResult
    public func recoverInterrupted() throws -> [String] {
        let legacy = try connection.prepare(
            "SELECT xmp_path FROM metadata_outbox WHERE status IN ('clean', 'cleaned') ORDER BY updated_at"
        ).query().compactMap { $0[0].textValue }
        for path in legacy {
            _ = try transition(
                xmpPath: path, from: [.clean, .cleaned], to: .synced, errorMessage: "")
        }
        let paths = try connection.prepare(
            "SELECT xmp_path FROM metadata_outbox WHERE status = 'writing' ORDER BY updated_at"
        ).query().compactMap { $0[0].textValue }
        guard !paths.isEmpty else { return [] }
        for row in try connection.prepare("SELECT * FROM metadata_outbox WHERE status = 'writing'").query()
            .map({ MetadataOutboxRow(row: $0) }) {
            _ = try transition(xmpPath: row.xmpPath, from: [.writing], to: .pending)
        }
        return paths
    }

    /// 运行期租约恢复：writing 行若不在本进程 activePaths 内、且租约已过期（updated_at ≤ now-leaseMs），
    /// 则归位：未达尝试上限 → pending；达上限 → failed（原因 XMP_WRITING_LEASE_EXPIRED）。
    /// 任何 writing 行都会在有限时间内被本函数处理，因此不存在"永远停在 writing"的行。
    @discardableResult
    public func recoverExpiredLeases(
        activePaths: Set<String>,
        leaseMs: Int = MetadataOutboxRepo.defaultLeaseMs,
        maxAttempts: Int = MetadataSyncLimits.maxAutomaticAttempts,
        now: Date = Date()
    ) throws -> [MetadataOutboxLeaseRecovery] {
        let cutoff = now.addingTimeInterval(-Double(leaseMs) / 1000)
        let rows = try connection.prepare(
            "SELECT * FROM metadata_outbox WHERE status = 'writing' ORDER BY updated_at"
        ).query().map { MetadataOutboxRow(row: $0) }
        var recovered: [MetadataOutboxLeaseRecovery] = []
        for row in rows {
            let path = MetadataOutboxPath.normalize(row.xmpPath)
            if activePaths.contains(path) { continue }
            if let claimedAt = MetadataOutboxRepo.parseTimestamp(row.updatedAt), claimedAt > cutoff { continue }
            if row.attemptCount >= Int64(maxAttempts) {
                _ = try transition(
                    xmpPath: path, from: [.writing], to: .failed,
                    errorMessage: "XMP_WRITING_LEASE_EXPIRED")
                recovered.append(MetadataOutboxLeaseRecovery(
                    xmpPath: path, newStatus: .failed, reason: "XMP_WRITING_LEASE_EXPIRED"))
            } else {
                _ = try transition(xmpPath: path, from: [.writing], to: .pending)
                recovered.append(MetadataOutboxLeaseRecovery(
                    xmpPath: path, newStatus: .pending, reason: "XMP_WRITING_LEASE_EXPIRED"))
            }
        }
        return recovered
    }

    /// 解析 updated_at（ISO8601 带/不带毫秒）。不可解析视为已过期（writing 必须有出口）。
    /// 解析器本体收敛到 RepositorySupport.tsParseISODate（含 "" 在内的不可解析输入均返回 nil）。
    public static func parseTimestamp(_ raw: String) -> Date? {
        tsParseISODate(raw)
    }

    // MARK: - 冲突裁决 / 会话确认 / 清理

    public func resolveConflict(
        xmpPath: String,
        patch: JSONValue,
        dirtyFields: [String],
        baselineFingerprint: String,
        baselineValues: JSONValue,
        acceptRemote: Bool
    ) throws {
        let path = MetadataOutboxPath.normalize(xmpPath)
        if acceptRemote {
            // 全部字段接受远程：不保留合成事务，直接结清（cleanup 不得再动外部 XMP）。
            try delete(path)
            return
        }
        var normalizedFields: [String: JSONValue] = [:]
        if case .object(let dict) = patch {
            normalizedFields = dict.filter { !OutboxPatchKey.reserved.contains($0.key) }
        }
        var owners: [String: String] = [:]
        if case .object(let dict) = patch, case .object(let existingOwners)? = dict[OutboxPatchKey.owners] {
            for (key, value) in existingOwners {
                if let module = value.stringValue, normalizedFields[key] != nil { owners[key] = module }
            }
        }
        var envelope = normalizedFields
        if !owners.isEmpty {
            envelope[OutboxPatchKey.owners] = .object(owners.mapValues { .string($0) })
        }
        let now = nowISOString()
        _ = try connection.prepare("""
            UPDATE metadata_outbox
            SET patch_json = ?, dirty_fields = ?, revision = revision + 1,
                base_fingerprint = ?, base_values_json = ?,
                status = 'pending', attempt_count = 0, error_message = '', updated_at = ?
            WHERE xmp_path = ? AND status = 'conflict'
          """).run([
            .text(try JSONValue.stringify(.object(envelope))),
            .text(try JSONValue.stringify(.array(dirtyFields.map { JSONValue.string($0) }))),
            .text(baselineFingerprint),
            .text(try JSONValue.stringify(baselineValues)),
            .text(now),
            .text(path),
          ])
        _ = try connection.prepare(
            "UPDATE metadata_outbox_sessions SET confirmed_at = '' WHERE xmp_path = ?"
        ).run([.text(path)])
    }

    /// 会话确认：确认是 **per (session, photo) 视图**，不是 per 字段归属——
    /// 只确认自己拥有的字段会让非归属会话永远无法确认共享行，行永远停在 written
    /// （cleanup 死锁）。因此确认覆盖本会话的全部链接行；行状态翻转仍要求**所有**
    /// 关联会话都已确认（下面的 NOT EXISTS 条件）。
    /// - Parameter sourceModule: 仅用于日志/诊断，不参与过滤（保持调用方签名稳定）。
    public func markSessionSynced(sessionId: String, sourceModule: String) throws {
        let now = nowISOString()
        try connection.transaction {
            let rows = try getBySession(sessionId)
            _ = sourceModule
            for row in rows {
                _ = try connection.prepare("""
                    UPDATE metadata_outbox_sessions SET confirmed_at = ?
                    WHERE session_id = ? AND xmp_path = ?
                  """).run([.text(now), .text(sessionId), .text(row.xmpPath)])
            }
            _ = try connection.prepare("""
                UPDATE metadata_outbox
                SET status = 'synced', updated_at = ?
                WHERE status = 'written'
                  AND EXISTS (
                    SELECT 1 FROM metadata_outbox_sessions os
                    WHERE os.xmp_path = metadata_outbox.xmp_path
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM metadata_outbox_sessions os
                    WHERE os.xmp_path = metadata_outbox.xmp_path
                      AND os.confirmed_at = ''
                  )
              """).run([.text(now)])
        }
    }

    /// 与 sessionId 共享侧车、但尚未确认的其它会话（confirmSync 的跨会话门）。
    /// 未确认 = 链接行 confirmed_at 为空，或（requireReloadAck 时）该会话无 reload-ack。
    public func unconfirmedLinkedSessions(sessionId: String, requireReloadAck: Bool) throws -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for row in try getBySession(sessionId) {
            for linked in try getSessionIds(row.xmpPath) where linked != sessionId && !seen.contains(linked) {
                let link = try connection.prepare("""
                    SELECT confirmed_at FROM metadata_outbox_sessions
                    WHERE xmp_path = ? AND session_id = ?
                  """).get([.text(row.xmpPath), .text(linked)])
                let confirmedAt = link?[0].textValue ?? ""
                let acked = try connection.prepare("SELECT reload_acked_at FROM sessions WHERE id = ?")
                    .get([.text(linked)])?[0].textValue ?? ""
                if confirmedAt.isEmpty || (requireReloadAck && acked.isEmpty) {
                    seen.insert(linked)
                    result.append(linked)
                }
            }
        }
        return result
    }

    /// 条件删除（D3 深审）：只有 revision 未变时才删除整行及其会话关联。
    /// 返回 false = 期间产生了新 revision（新输入必须保留，不能清掉）。
    @discardableResult
    public func deleteIfRevision(_ xmpPath: String, revision: Int64) throws -> Bool {
        let changes = try connection.prepare(
            "DELETE FROM metadata_outbox WHERE xmp_path = ? AND revision = ?"
        ).run([.text(xmpPath), .int(revision)])
        guard changes > 0 else { return false }
        try connection.prepare("DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?").run([.text(xmpPath)])
        return true
    }

    public func delete(_ xmpPath: String) throws {
        let path = MetadataOutboxPath.normalize(xmpPath)
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ?").run([.text(path)])
            _ = try connection.prepare("DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?").run([.text(path)])
        }
    }

    public func deleteByRevision(xmpPath: String, revision: Int64) throws {
        let path = MetadataOutboxPath.normalize(xmpPath)
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ? AND revision = ?")
                .run([.text(path), .int(revision)])
            _ = try connection.prepare("""
                DELETE FROM metadata_outbox_sessions
                WHERE xmp_path = ? AND NOT EXISTS (
                  SELECT 1 FROM metadata_outbox WHERE xmp_path = ?
                )
              """).run([.text(path), .text(path)])
        }
    }
}

/// 写回内核共享的常量（仓库与协调器同一真相源）。
public enum MetadataSyncLimits {
    /// 自动写入的总尝试次数（含首次）。第 maxAutomaticAttempts 次失败后转 failed，不再重排。
    public static let maxAutomaticAttempts = 5
    /// 重试退避档位：**maxAutomaticAttempts - 1 档**（第 1 次失败用 delay[0]，……，
    /// 第 4 次失败用 delay[3]；第 5 次失败即终态）。档位数与实现严格一致，不再有不可达档位。
    public static let retryDelaysMs: [Int] = [1_000, 2_000, 5_000, 15_000]
}
