// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Transitions.swift
// DeliveryRepo 拆分（纯移动）：状态迁移 / 租约 / CAS。
//
// 方法体与拆分前逐字一致；跨文件 private 成员仅提升为 internal。

import Foundation
import GatherProtocol

extension DeliveryRepo {
    // MARK: - 状态迁移（CAS）

    /// pending/failed/conflict → writing（租约起点；attempt_count + 1）。
    ///
    /// P2 收口：生产代码只用 `claimWriting`（带租约）；本方法只为既有测试/
    /// 无租约的底层迁移：仅包内测试/嵌入夹具使用，生产必须走 claimWriting。
    /// 已降为 internal；跨包 app 测试经 GatherTestSupport.markWritingForTesting 访问。
    @discardableResult
    package func markWriting(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String = "",
        heartbeatAt: String? = nil
    ) throws -> DeliveryRow? {
        try casTransition(
            xmpPath: xmpPath,
            revision: revision,
            to: .writing,
            assignments: [
                "attempt_count = attempt_count + 1",
                "lease_owner = ?",
                "heartbeat_at = ?",
                "error_message = ''",
            ],
            values: [.text(leaseOwner), .text(heartbeatAt ?? nowISOString())]
        )
    }

    /// writing 租约有效期（P1-2）：heartbeat 超过它的 writing 行视为崩溃遗留，可被抢占。
    public static let writingLeaseTTLSeconds: TimeInterval = 300

    /// 抢写租约（P1-2）：pending/failed/conflict → writing；已经 writing 时按租约处理。
    ///
    /// 租约规则（唯一入口；markWriting 仍是无租约的底层迁移，供短事务写者使用）：
    /// - 同一 leaseOwner：续租（刷新 heartbeat，**不**增加 attempt_count）；
    /// - 不同 owner 且 heartbeat 为空或早于 TTL：视为崩溃遗留，抢占并写新 owner/heartbeat
    ///   （attempt_count + 1）；
    /// - 不同 owner 且 heartbeat 未过期：拒绝，抛 DeliveryRepoError.leaseHeld，
    ///   不返回 nil（nil 只表示 revision/状态 CAS 失配，不能与租约冲突混淆）。
    ///
    /// - Parameter now: 判定过期的时间基准（默认当前时间，测试可注入）。
    @discardableResult
    public func claimWriting(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String,
        heartbeatAt: String? = nil,
        now: Date = Date()
    ) throws -> DeliveryRow? {
        guard !leaseOwner.isEmpty else {
            throw DeliveryRepoError.invalidArgument("claimWriting 必须提供非空 leaseOwner")
        }
        let path = try normalizedPath(xmpPath)
        guard let current = try get(path) else {
            throw DeliveryRepoError.rowNotFound(xmpPath: path)
        }
        guard let typed = current.typedStatus, typed.canTransition(to: .writing) else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: path, from: current.status, to: DeliveryStatus.writing.rawValue)
        }
        let nowText = isoString(now)
        let expiredBefore = isoString(now.addingTimeInterval(-Self.writingLeaseTTLSeconds))
        if typed == .writing, current.leaseOwner != leaseOwner,
           !current.heartbeatAt.isEmpty, current.heartbeatAt >= expiredBefore {
            throw DeliveryRepoError.leaseHeld(
                xmpPath: path,
                leaseOwner: current.leaseOwner,
                heartbeatAt: current.heartbeatAt)
        }
        // 租约判定在 SQL 里再做一次（读与写之间可能被并发续租）：只有同 owner、
        // 或 heartbeat 为空/过期的 writing 行才能被本 owner 改写。
        let changed = try connection.prepare("""
            UPDATE deliveries
            SET status = ?, lease_owner = ?, heartbeat_at = ?, error_message = '',
                attempt_count = attempt_count + CASE
                  WHEN status = ? AND lease_owner = ? THEN 0 ELSE 1 END,
                updated_at = ?
            WHERE xmp_path = ? AND revision = ?
              AND status IN (\(Self.allowedFromSQL(for: .writing)))
              AND (
                status <> ?
                OR lease_owner = ?
                OR heartbeat_at = ''
                OR heartbeat_at < ?
              )
            """).run([
                .text(DeliveryStatus.writing.rawValue), .text(leaseOwner),
                .text(heartbeatAt ?? nowText),
                .text(DeliveryStatus.writing.rawValue), .text(leaseOwner),
                .text(nowText),
                .text(path), .int(revision),
                .text(DeliveryStatus.writing.rawValue), .text(leaseOwner), .text(expiredBefore),
            ])
        guard changed == 1 else { return nil }
        return try get(path)
    }

    /// 同 owner 心跳续租（不推进 attempt_count）。
    ///
    /// 返回 false 表示租约已不属于本 owner（revision 推进、状态离开 writing 或被抢占），
    /// 调用方必须把它当成「租约丢失」显式上报，而不是静默继续。
    public func renewWriting(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String,
        heartbeatAt: String? = nil
    ) throws -> Bool {
        guard !leaseOwner.isEmpty else {
            throw DeliveryRepoError.invalidArgument("renewWriting 必须提供非空 leaseOwner")
        }
        let path = try normalizedPath(xmpPath)
        let nowText = nowISOString()
        let changed = try connection.prepare("""
            UPDATE deliveries SET heartbeat_at = ?, updated_at = ?
            WHERE xmp_path = ? AND revision = ? AND status = ? AND lease_owner = ?
            """).run([
                .text(heartbeatAt ?? nowText), .text(nowText), .text(path),
                .int(revision), .text(DeliveryStatus.writing.rawValue), .text(leaseOwner),
            ])
        return changed == 1
    }

    /// writing → written：落盘成功，记录基线指纹 / 基线快照 / 备份路径。
    ///
    /// P1-2：写入口必须带 leaseOwner。CAS 同时匹配 revision、状态集合与
    /// `lease_owner`；owner 不匹配（租约被接管/被新输入重开/已收敛）时抛
    /// `DeliveryRepoError.leaseLost` 且**不触碰行**，旧写者不能覆盖新基线。
    ///
    /// `leaseOwner` 缺省为空串，保留给尚未持有唯一租约的短事务调用方
    /// （Host 的 acceptExternalState / 既有测试）；空串同样做 owner CAS，
    /// 只是 CAS 失配时返回 nil（旧语义），不抛 leaseLost。
    @discardableResult
    public func markWritten(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String = "",
        baseFingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) throws -> DeliveryRow? {
        try leaseAwareTransition(
            xmpPath: xmpPath,
            revision: revision,
            to: .written,
            leaseOwner: leaseOwner,
            assignments: [
                "base_fingerprint = ?",
                "base_values_json = ?",
                "backup_path = ?",
                "lease_owner = ''",
                "heartbeat_at = ''",
                "error_message = ''",
            ],
            values: [
                .text(baseFingerprint),
                .text(try JSONValue.stringify(baseValues)),
                .text(backupPath),
            ]
        )
    }

    /// markWritten + 关联会话 reload-ack 清零的**同一事务**入口（P2）。
    /// 旧实现先 markWritten、再单独 clearReloadAck；中间窗口内 confirm 可能用旧 ack
    /// 确认新内容。这里用外层事务包住两步（markWritten 内部 SAVEPOINT 嵌套）。
    @discardableResult
    public func markWrittenAndClearReloadAcks(
        xmpPath: String,
        revision: Int64,
        leaseOwner: String,
        baseFingerprint: String,
        baseValues: JSONValue,
        backupPath: String,
        timestamp: String
    ) throws -> DeliveryRow? {
        try connection.transaction {
            guard let row = try markWritten(
                xmpPath: xmpPath,
                revision: revision,
                leaseOwner: leaseOwner,
                baseFingerprint: baseFingerprint,
                baseValues: baseValues,
                backupPath: backupPath
            ) else { return nil }
            try SessionReloadAckRepo(connection: connection)
                .clearReloadAcks(forXmpPath: xmpPath, timestamp: timestamp)
            return row
        }
    }

    /// markWritten / markFailed / markConflict 共用的**租约 owner CAS**（P1-2 / P2）。
    ///
    /// 口径与 markWritten 完全一致，避免三个写入口各写一套：
    /// - 非空 owner：先快速失败（行已不在 writing 或 owner 已变 → leaseLost），
    ///   再让 CAS 带 `lease_owner = ?`；CAS 失配后复核，只有 owner/状态确实漂移
    ///   才抛 leaseLost，普通 revision/状态竞争仍返回 nil；
    /// - 空 owner：同样带 `lease_owner = ''` CAS（不可能覆盖别人的租约），
    ///   CAS 失配返回 nil。cleanup/replay 的 conflict 标记没有租约，正是这条路径。
    ///
    /// 行始终保留（只读复核，不覆盖）；调用方据 nil / leaseLost 放弃本轮收敛。
    private func leaseAwareTransition(
        xmpPath: String,
        revision: Int64,
        to target: DeliveryStatus,
        leaseOwner: String,
        assignments: [String],
        values: [DBValue?]
    ) throws -> DeliveryRow? {
        let path = try normalizedPath(xmpPath)
        if !leaseOwner.isEmpty {
            if let current = try get(path),
               current.leaseOwner != leaseOwner
                   || current.status != DeliveryStatus.writing.rawValue {
                throw DeliveryRepoError.leaseLost(
                    xmpPath: path,
                    leaseOwner: leaseOwner,
                    currentOwner: current.leaseOwner,
                    status: current.status)
            }
        }
        let row = try casTransition(
            xmpPath: path,
            revision: revision,
            to: target,
            assignments: assignments,
            values: values,
            requiringLeaseOwner: leaseOwner
        )
        guard row == nil, !leaseOwner.isEmpty else { return row }
        if let current = try get(path),
           current.status != DeliveryStatus.writing.rawValue || current.leaseOwner != leaseOwner {
            throw DeliveryRepoError.leaseLost(
                xmpPath: path,
                leaseOwner: leaseOwner,
                currentOwner: current.leaseOwner,
                status: current.status)
        }
        return nil
    }

    /// written → synced（会话确认；confirm 的事务版走 confirm，不走本方法）。
    @discardableResult
    public func markSynced(xmpPath: String, revision: Int64) throws -> DeliveryRow? {
        try casTransition(
            xmpPath: xmpPath,
            revision: revision,
            to: .synced,
            assignments: ["lease_owner = ''", "heartbeat_at = ''"],
            values: []
        )
    }

    /// 单条原子迁移：校验当前态 → 用「迁移表允许的来源态集合 + revision」做 CAS。
    /// 返回 nil 表示 CAS 失败（不是错误：并发迁移/新 revision 抢先）。
    private func casTransition(
        xmpPath: String,
        revision: Int64,
        to target: DeliveryStatus,
        assignments: [String],
        values: [DBValue?],
        requiringLeaseOwner leaseOwner: String? = nil
    ) throws -> DeliveryRow? {
        let path = try normalizedPath(xmpPath)
        guard let current = try get(path) else {
            throw DeliveryRepoError.rowNotFound(xmpPath: path)
        }
        guard let typed = current.typedStatus else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: path, from: current.status, to: target.rawValue)
        }
        guard typed.canTransition(to: target) else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: path, from: typed.rawValue, to: target.rawValue)
        }
        let sets = assignments + ["status = ?", "updated_at = ?"]
        var sql = """
            UPDATE deliveries SET \(sets.joined(separator: ", "))
            WHERE xmp_path = ? AND revision = ? AND status IN (\(Self.allowedFromSQL(for: target)))
            """
        var parameters = values + [
            .text(target.rawValue), .text(nowISOString()), .text(path), .int(revision),
        ]
        if let leaseOwner {
            sql += " AND lease_owner = ?"
            parameters.append(.text(leaseOwner))
        }
        let changed = try connection.prepare(sql).run(parameters)
        guard changed == 1 else { return nil }
        return try get(path)
    }

    /// 迁移表反向查询：所有能到达 target 的来源态（SQL IN 片段，值来自 enum 字面量）。
    private static func allowedFromSQL(for target: DeliveryStatus) -> String {
        DeliveryStatus.allCases
            .filter { $0.canTransition(to: target) }
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
    }

    // MARK: - 新输入合并（revision CAS）

    /// 新输入到达时合并 revision/photo_path/基线并把状态重新打开为 pending。
    ///
    /// 语义（D-023 第 3 条 + D-031）：
    /// - revision 是输入版本号：本方法把它推进到 newRevision，成功后写入者用新 revision
    ///   抢租约；旧 revision 的 markWritten 会因 CAS 失败而不会覆盖新输入。
    /// - base_fingerprint/base_values_json 属于「新输入的基线」，随 revision 一起刷新；
    /// - photo_path 可随输入更新（如照片路径被重新定位），xmp_path 主键不变；
    /// - **status 置 pending**（D-031）：written/synced/failed/conflict（以及 writing）
    ///   收到新输入后不能停留在旧状态，否则 confirm 会把已写/已确认的旧结果当成新输入；
    ///   同时清空租约与 error_message，避免 pending 行携带上一轮的写入上下文。
    ///   pending 的来源集合由 `DeliveryStatus.canTransition(to: .pending)` 派生，
    ///   cleaned 是审计终态，不在集合内（要重写就新建行）。
    /// - **所有关联会话的 confirmed_at 置 ''**（P1-1）：新输入的确认必须覆盖所有
    ///   链接会话，不能只让当前会话重新确认；否则其他会话的旧确认会通过
    ///   confirm 的跨会话门禁，单会话即可把 delivery 翻回 synced。
    ///   清空与 CAS 在同一事务内，CAS 失配（返回 nil）时不触碰任何链接。
    /// - **不改 delivery_items**（items 由 upsertItem/discard 各自管理）。
    ///
    /// 返回 nil 只表示 CAS 失配（revision 过期或状态是 cleaned）；
    /// 行不存在仍抛 rowNotFound（写入口不得静默 no-op）。
    @discardableResult
    public func mergeInput(
        xmpPath: String,
        photoPath: String,
        expectedRevision: Int64,
        newRevision: Int64,
        baseFingerprint: String,
        baseValues: JSONValue
    ) throws -> DeliveryRow? {
        let path = try normalizedPath(xmpPath)
        guard expectedRevision >= 0, newRevision >= 0 else {
            throw DeliveryRepoError.invalidArgument(
                "revision 不能为负: expected=\(expectedRevision) new=\(newRevision)")
        }
        guard newRevision >= expectedRevision else {
            throw DeliveryRepoError.invalidArgument(
                "newRevision 不能小于 expectedRevision: \(newRevision) < \(expectedRevision)")
        }
        let baseJSON = try JSONValue.stringify(baseValues)
        return try connection.transaction {
            // pending 的来源集合由状态机派生（D-031）：writing/written/synced/failed/
            // conflict 都允许被新输入重新打开；cleaned 不在集合内，CAS 返回 nil。
            let changed = try connection.prepare("""
                UPDATE deliveries
                SET revision = ?, photo_path = ?, base_fingerprint = ?,
                    base_values_json = ?, status = ?, lease_owner = '', heartbeat_at = '',
                    error_message = '', updated_at = ?
                WHERE xmp_path = ? AND revision = ?
                  AND status IN (\(Self.allowedFromSQL(for: .pending)))
                """).run([
                    .int(newRevision), .text(photoPath), .text(baseFingerprint),
                    .text(baseJSON), .text(DeliveryStatus.pending.rawValue),
                    .text(nowISOString()), .text(path), .int(expectedRevision),
                ])
            guard changed == 1 else {
                // 区分「行不存在」与「CAS 失配」：前者是调用方 bug，必须显式失败。
                guard try get(path) != nil else {
                    throw DeliveryRepoError.rowNotFound(xmpPath: path)
                }
                return nil
            }
            guard let row = try get(path) else {
                throw DeliveryRepoError.writeNotPersisted(path)
            }
            // 新输入使该交付的**所有**关联会话确认失效（P1-1）：只清当前会话会让
            // 其他会话的旧 confirmed_at 继续通过 confirm 的跨会话门禁，单会话即可
            // 把别人的旧确认当成对新内容的确认。与上面的 CAS 同事务，CAS 失配时
            // 不触碰任何 confirmed_at（否则会白清别人的确认）。
            _ = try connection.prepare("""
                UPDATE delivery_sessions SET confirmed_at = ''
                WHERE delivery_id = ? AND confirmed_at <> ''
                """).run([.int(row.id)])
            return row
        }
    }

    // MARK: - 确认失效（P1-10）

    /// 使该交付的全部关联会话确认失效：单事务把 delivery_sessions.confirmed_at 置 ''。
    ///
    /// 使用场景是「外部内容被采纳为新基线」（resolveConflict 全部 use_remote）：
    /// 旧确认针对的是冲突前的旧内容，不能作为新基线的确认通过 confirm 的跨会话门禁。
    /// 与 mergeInput 的内联清理同一语义，但这里不推进 revision / 不改交付状态——
    /// 调用方负责在推进到 written 的同一流程里清空，再让各会话重新确认。
    ///
    /// 返回**本次实际清空的行数**（原本已为 '' 的会话不计数，重复调用返回 0）。
    /// 行不存在抛 rowNotFound（写入口不得静默 no-op）；无关联会话返回 0（幂等）。
    @discardableResult
    public func resetConfirmations(xmpPath: String) throws -> Int {
        let path = try normalizedPath(xmpPath)
        return try connection.transaction {
            guard let row = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            return try connection.prepare("""
                UPDATE delivery_sessions SET confirmed_at = ''
                WHERE delivery_id = ? AND confirmed_at <> ''
                """).run([.int(row.id)])
        }
    }

    // MARK: - 失败 / 冲突 / 会话链接

    /// 写入失败：pending/writing/failed → failed（清租约、记原因；可重试回 writing）。
    ///
    /// P2：写入口与 markWritten 同口径——`leaseOwner` 非空时 CAS 必须匹配
    /// `lease_owner`（租约被接管/新输入重开时抛 leaseLost，旧写者不得把新基线
    /// 标成 failed）；缺省空串只允许 owner 为空的行，cleanup/replay 的失败路径
    /// 因此不会覆盖正在写盘的租约。
    @discardableResult
    public func markFailed(
        xmpPath: String,
        revision: Int64,
        errorMessage: String,
        leaseOwner: String
    ) throws -> DeliveryRow? {
        try leaseAwareTransition(
            xmpPath: xmpPath,
            revision: revision,
            to: .failed,
            leaseOwner: leaseOwner,
            assignments: ["error_message = ?", "lease_owner = ''", "heartbeat_at = ''"],
            values: [.text(errorMessage)]
        )
    }

    /// 外部修改冲突：pending/writing/written/synced/failed → conflict（裁决后回 pending/writing）。
    ///
    /// P2：与 markWritten/markFailed 同一 owner CAS 口径。cleanup/replay 不持租约，
    /// 传空串只允许 `lease_owner = ''` 的行；正在写盘的交付不会被清理路径抢先标
    /// conflict（CAS 返回 nil，调用方按 skipped 处理）。
    @discardableResult
    public func markConflict(
        xmpPath: String,
        revision: Int64,
        errorMessage: String,
        leaseOwner: String
    ) throws -> DeliveryRow? {
        try leaseAwareTransition(
            xmpPath: xmpPath,
            revision: revision,
            to: .conflict,
            leaseOwner: leaseOwner,
            assignments: ["error_message = ?", "lease_owner = ''", "heartbeat_at = ''"],
            values: [.text(errorMessage)]
        )
    }

    // 包内测试夹具：owner 为空串（只允许租约为空的行）。生产必须走 StateWriter 并显式传 owner。
    @discardableResult
    package func markFailedForTesting(
        xmpPath: String, revision: Int64, errorMessage: String, leaseOwner: String = ""
    ) throws -> DeliveryRow? {
        try markFailed(xmpPath: xmpPath, revision: revision,
                       errorMessage: errorMessage, leaseOwner: leaseOwner)
    }

    @discardableResult
    package func markConflictForTesting(
        xmpPath: String, revision: Int64, errorMessage: String, leaseOwner: String = ""
    ) throws -> DeliveryRow? {
        try markConflict(xmpPath: xmpPath, revision: revision,
                         errorMessage: errorMessage, leaseOwner: leaseOwner)
    }
}
