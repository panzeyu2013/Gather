// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/MetadataRetentionService.swift
// P1 下一波 §3.1.4：metadata/template 交付与备份的**保留期回收**。
//
// 五件事，按顺序执行（每一步都可单独失败，失败只进 errors，不影响其它步）：
// 1. 存量收编：仅有 metadata/template item、状态 written、无未完成 intent、照片仍在
//    的交付按新策略自动确认（写入成功过一次，缺的只是确认动作）；
// 2. 保留期回收：synced + 超过 metadata_backup_retention_days + 无未完成 intent，
//    走 DeliveryCoordinator.finalizeForRetention（**同一条 intent 前滚**，不另写
//    删除逻辑）；备份删除在 DB 事务提交之后；
// 3. 零 item 行（photo 被删导致 CASCADE 清空 items）：删行 + 备份；
// 4. 文件已消失行（xmp_path 不存在且无未完成 intent）：删行 + 既有备份；
// 5. 孤儿备份：只在会话根目录**第一层**找受控命名（.gather-backup-/.gather-header-）
//    且 mtime > 24h 且 DB 无 backup_path 指向它的文件；判定改用锚定式
//    DeliveryBackupPath.anchoredXMPPath（从文件名反推 <xmp> 并复用 validate 的
//    同目录/前缀/非常规文件校验），绝不按"名字含标记"盲删（P1-4）；同一循环顺手
//    回收崩溃残留的 `.<photo>.gather-embedded-<uuid>` 照片拷贝临时文件（C6，
//    独立计数，不进备份集合）。
//
// 会话作用域（P1-2）：run(policy:sessionId:) 的 sessionId 为 nil = 全局回收
// （后台 24h job 只走这条）；非 nil 时只处理与该会话关联的交付，绝不碰其它会话的
// 行与备份——"立即清理已确认备份"是会话内动作，原实现忽略 sessionId，会把它跑成
// "确认并删除所有会话的已确认交付与备份"。
//
// 3/4/5 三条清理都在 policy.isEnabled 之内（P1-3）：metadata_backup_retention_days=0
// 的语义是"不自动删"，设置必须能阻止这三条；手动"立即清理"（.immediate）的
// isEnabled=true，因此仍然照常执行。
//
// 不可回收的三种：written/pending/conflict 一律跳过（备份是用户唯一撤销点）；
// C1 门禁生效且会话未 reload-ack 时跳过 2（C1 仍显示旧值，备份是唯一还原点），
// 用户可在设置页"立即清理"里显式忽略（policy.ignoreReloadAck）。
//
// 单次最多处理 batchLimit 条（默认 200）：避免长事务，进度由宿主后台 job 呈现。
// 所有日志只输出 basename#hash，完整路径只留在返回的 errors 里。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

// MARK: - 策略与结果

/// 回收策略（设置页/后台任务/测试共用）。
public struct MetadataRetentionPolicy: Sendable, Equatable {
    /// 已确认交付的保留天数（0 = "立刻可回收"，配合 isEnabled 使用）。
    public var retentionDays: Int
    /// 是否按保留期回收。设置项 metadata_backup_retention_days=0 表示"不自动删"，
    /// 调用方据此传 false；手动"立即清理"传 true（retentionDays 可保持 0）。
    public var isEnabled: Bool
    /// 单次最多处理的交付数。
    public var batchLimit: Int
    /// 手动"立即清理"：显式忽略 C1 reload-ack 门禁（默认 false = 遵守门禁）。
    public var ignoreReloadAck: Bool
    /// 是否扫描孤儿备份（默认开；测试可关掉以便只断言行/备份对）。
    public var includeOrphanBackups: Bool
    /// 是否做存量收编（幂等，默认开）。
    public var adoptLegacyRows: Bool

    public init(
        retentionDays: Int = 7,
        isEnabled: Bool = true,
        batchLimit: Int = 200,
        ignoreReloadAck: Bool = false,
        includeOrphanBackups: Bool = true,
        adoptLegacyRows: Bool = true
    ) {
        self.retentionDays = retentionDays
        self.isEnabled = isEnabled
        self.batchLimit = batchLimit
        self.ignoreReloadAck = ignoreReloadAck
        self.includeOrphanBackups = includeOrphanBackups
        self.adoptLegacyRows = adoptLegacyRows
    }

    /// 从设置读（metadata_backup_retention_days；0 = 关闭自动回收）。
    public static func fromSettings(
        _ get: (String, String) -> String,
        ignoreReloadAck: Bool = false
    ) -> MetadataRetentionPolicy {
        let raw = get(MetadataDeliveryService.retentionDaysKey, "7")
        let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let days = max(0, parsed ?? 7)
        return MetadataRetentionPolicy(
            retentionDays: days,
            isEnabled: days > 0,
            ignoreReloadAck: ignoreReloadAck
        )
    }

    /// 手动"立即清理"：忽略保留期与 C1 门禁（用户显式动作）。
    public static let immediate = MetadataRetentionPolicy(
        retentionDays: 0,
        isEnabled: true,
        ignoreReloadAck: true
    )
}

/// 一次回收的结果（设置页/日志/后台 job 的摘要）。
public struct MetadataRetentionResult: Sendable, Equatable {
    /// 进入保留期候选的交付数。
    public var scanned: Int
    /// 行 + 备份都删掉的交付数。
    public var deletedDeliveries: Int
    /// 只删了本模块 item、行/备份保留的交付数（共享文件还有其它模块 item）。
    public var retainedDeliveries: Int
    /// 因未 ack / 未确认 / 有未完成 intent 等原因跳过的数量。
    public var skipped: Int
    public var errors: [String]
    /// 存量收编确认的交付数。
    public var adopted: Int
    public var orphanBackupsDeleted: Int
    /// 崩溃残留的内嵌写回临时文件（`.<photo>.gather-embedded-<uuid>`）被删数；
    /// 与 orphanBackupsDeleted 分开计数：它们不是备份，不能进撤销点统计（C6）。
    public var embeddedTempsDeleted: Int
    public var emptyRowsDeleted: Int
    public var vanishedRowsDeleted: Int
    public var backupBytesFreed: Int64

    public init(
        scanned: Int = 0,
        deletedDeliveries: Int = 0,
        retainedDeliveries: Int = 0,
        skipped: Int = 0,
        errors: [String] = [],
        adopted: Int = 0,
        orphanBackupsDeleted: Int = 0,
        embeddedTempsDeleted: Int = 0,
        emptyRowsDeleted: Int = 0,
        vanishedRowsDeleted: Int = 0,
        backupBytesFreed: Int64 = 0
    ) {
        self.scanned = scanned
        self.deletedDeliveries = deletedDeliveries
        self.retainedDeliveries = retainedDeliveries
        self.skipped = skipped
        self.errors = errors
        self.adopted = adopted
        self.orphanBackupsDeleted = orphanBackupsDeleted
        self.embeddedTempsDeleted = embeddedTempsDeleted
        self.emptyRowsDeleted = emptyRowsDeleted
        self.vanishedRowsDeleted = vanishedRowsDeleted
        self.backupBytesFreed = backupBytesFreed
    }
}

// MARK: - 服务

public struct MetadataRetentionService: Sendable {
    /// 零 item 行的最小年龄：mirror/legacy 写路径可能"先建行、后插 item"（两个事务），
    /// 一小时内不动，避免把正要写入的交付当孤儿删掉。
    static let emptyRowMinimumAgeSeconds: TimeInterval = 3600
    /// 孤儿备份的最小年龄（mtime 早于 24h）。
    static let orphanBackupMinimumAgeSeconds: TimeInterval = 86_400

    private let connection: DBConnection
    private let lifecycle: MetadataLifecycleRepo
    private let coordinator: DeliveryCoordinator
    private let now: @Sendable () -> Date

    public init(
        connection: DBConnection,
        coordinator: DeliveryCoordinator,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connection = connection
        self.lifecycle = MetadataLifecycleRepo(connection: connection)
        self.coordinator = coordinator
        self.now = now
    }

    // MARK: - 入口

    /// 跑一遍回收（幂等；重复跑只会处理剩下的候选）。
    ///
    /// - Parameter sessionId: 会话作用域（P1-2）。nil = 全局（后台 24h job 只走这条，
    ///   别把后台回收锁进某一个会话）；非 nil = 只处理与该会话关联的交付。
    public func run(
        policy: MetadataRetentionPolicy,
        sessionId: String? = nil
    ) async -> MetadataRetentionResult {
        var result = MetadataRetentionResult()
        let limit = max(1, policy.batchLimit)
        // 空串按"全局"处理：MetadataCleanupInput.sessionId 是必填 String，调用方
        // 若给了空串，绝不能把它当成一个真实会话去作用域过滤（那会静默什么都不做）。
        let scope = sessionId.flatMap { $0.isEmpty ? nil : $0 }
        // 候选查询没有按会话过滤的重载（MetadataLifecycleRepo 不在本组文件清单）：
        // 会话作用域下先多取几倍再在 Application 侧过滤，避免"前 limit 条全是别的
        // 会话"把本会话饿死；仍然是有界查询。
        let queryLimit = Self.candidateQueryLimit(limit, scoped: scope != nil)

        if policy.adoptLegacyRows {
            let adoption = await adoptLegacyRows(
                limit: limit, queryLimit: queryLimit, sessionId: scope)
            result.adopted = adoption.adopted
            result.skipped += adoption.skipped
            result.errors.append(contentsOf: adoption.errors)
        }
        if policy.isEnabled {
            // async 段单独取返回值再合并：inout 跨 await 不做（可读性 + 互斥访问）。
            let retention = await retainExpired(
                policy: policy, limit: limit, queryLimit: queryLimit, sessionId: scope)
            result.scanned += retention.scanned
            result.deletedDeliveries += retention.deletedDeliveries
            result.retainedDeliveries += retention.retainedDeliveries
            result.skipped += retention.skipped
            result.errors.append(contentsOf: retention.errors)
            // P1-3：三条清理纳入 isEnabled——原实现把它们放在 if 之外，
            // metadata_backup_retention_days=0（"不自动删"）时仍会删备份。
            purgeEmptyRows(
                limit: limit, queryLimit: queryLimit, sessionId: scope, result: &result)
            purgeVanishedRows(
                limit: limit, queryLimit: queryLimit, sessionId: scope, result: &result)
            // 孤儿备份回收是**全局**维护动作：扫描根是 sessions.source_path，按会话
            // 限定引用集合会让其它会话仍在用的备份看起来像孤儿（删错方向）。会话作用域
            // 的清理只做"与本会话相关的行 + 它们的备份"。
            if policy.includeOrphanBackups {
                if scope == nil {
                    purgeOrphanBackups(result: &result)
                } else {
                    GatherLogger.log(
                        "trace=gc/deletions phase=orphans skipped=session-scope "
                            + "session=\(MetadataDeliveryService.sessionToken(scope ?? ""))",
                        level: .debug)
                }
            }
        }

        GatherLogger.log(
            "trace=gc/deletions phase=summary scanned=\(result.scanned) "
                + "deleted=\(result.deletedDeliveries) retained=\(result.retainedDeliveries) "
                + "skipped=\(result.skipped) adopted=\(result.adopted) "
                + "orphan_backups=\(result.orphanBackupsDeleted) "
                + "embedded_temps=\(result.embeddedTempsDeleted) "
                + "empty_rows=\(result.emptyRowsDeleted) "
                + "vanished_rows=\(result.vanishedRowsDeleted) "
                + "errors=\(result.errors.count)",
            level: .info)
        return result
    }

    /// 会话作用域下的候选查询放大倍数（见 run 里的说明；默认 200 → 1,600 行）。
    static let scopedQueryFactor = 8

    static func candidateQueryLimit(_ limit: Int, scoped: Bool) -> Int {
        guard scoped else { return limit }
        guard limit <= Int.max / scopedQueryFactor else { return Int.max }
        return limit * scopedQueryFactor
    }

    /// 会话作用域复核：交付是否关联该会话（nil = 全局，恒 true）。
    ///
    /// 复用既有 `linkedSessions(deliveryId:)`（retainExpired 本来就要读它做 reload-ack
    /// 判定），不为此新增跨文件的公开 API；查询失败按"不在作用域"跳过并记错误。
    private func isInScope(
        deliveryId: Int64,
        sessionId: String?,
        errors: inout [String]
    ) -> Bool {
        guard let sessionId else { return true }
        do {
            let sessions = try linkedSessions(deliveryId: deliveryId)
            return sessions.contains { $0.id == sessionId }
        } catch {
            errors.append(
                "METADATA_RETENTION_SCOPE_QUERY_FAILED: delivery=\(deliveryId) "
                    + "reason=\(String(describing: error))")
            return false
        }
    }

    // MARK: - 1. 存量收编

    private struct AdoptionCandidate {
        let xmpPath: String
        let photoPath: String
        let sessionId: String
    }

    /// 仅有 metadata/template item、状态 written、无未完成 intent、照片仍在的交付
    /// 按新策略自动确认（写入成功过一次，缺的只是确认动作）。
    ///
    /// 逐会话 confirm（scope=.module）：一个会话里有 failed/conflict 时该会话整体
    /// 被门禁挡住（计入 skipped），不会"收编一半"。failed/conflict 行本身不碰。
    private func adoptLegacyRows(
        limit: Int,
        queryLimit: Int,
        sessionId: String?
    ) async -> (adopted: Int, skipped: Int, errors: [String]) {
        var adopted = 0
        var skipped = 0
        var errors: [String] = []
        var rows: [AdoptionCandidate]
        do {
            rows = try lifecycle.adoptionCandidates(limit: queryLimit).map {
                AdoptionCandidate(
                    xmpPath: $0.xmpPath, photoPath: $0.photoPath,
                    sessionId: $0.sessionId)
            }
        } catch {
            errors.append("METADATA_RETENTION_ADOPT_QUERY_FAILED: \(String(describing: error))")
            return (0, 0, errors)
        }
        // 会话作用域（P1-2）：收编的落点是 synced，而 synced 是"所有关联会话都已
        // 确认"的跨会话结论；在 A 会话点"立即清理"绝不能把 B 会话的 written 收编。
        if let sessionId {
            rows = rows.filter { $0.sessionId == sessionId }
        }
        if rows.count > limit {
            rows = Array(rows.prefix(limit))
        }
        // 照片仍在才收编：文件都没了，确认只会把不可写的行推成 synced。
        var sessions = Set<String>()
        for row in rows {
            let photoExists = !row.photoPath.isEmpty
                && FileManager.default.fileExists(atPath: row.photoPath)
            let targetExists = FileManager.default.fileExists(atPath: row.xmpPath)
            if photoExists || targetExists {
                sessions.insert(row.sessionId)
            } else {
                skipped += 1
            }
        }
        // 变量名不叫 sessionId：外层参数就是会话作用域，混淆会让"作用域过滤"
        // 与"逐会话 confirm"看起来是同一件事。
        for linkedSession in sessions.sorted() {
            do {
                let summary = try coordinator.confirm(sessionId: linkedSession, module: .metadata)
                adopted += summary.deliveriesSynced
                if summary.deliveriesSynced > 0 {
                    GatherLogger.log(
                        "trace=gc/adopt session="
                            + "\(MetadataDeliveryService.sessionToken(linkedSession)) "
                            + "deliveries=\(summary.deliveriesSynced) items=\(summary.itemsSynced)",
                        level: .info)
                }
            } catch {
                // 门禁（未确认项/未 reload）或并发状态变化：跳过该会话，下次再来。
                skipped += 1
                errors.append(
                    "METADATA_RETENTION_ADOPT_SKIPPED: "
                        + "\(MetadataDeliveryService.sessionToken(linkedSession)) "
                        + "reason=\(String(describing: error))")
            }
        }
        return (adopted, skipped, errors)
    }

    // MARK: - 2. 保留期回收

    private struct RetentionCandidate {
        let id: Int64
        let xmpPath: String
        let backupPath: String
    }

    private func retainExpired(
        policy: MetadataRetentionPolicy,
        limit: Int,
        queryLimit: Int,
        sessionId: String?
    ) async -> MetadataRetentionResult {
        var result = MetadataRetentionResult()
        let cutoff = isoString(now().addingTimeInterval(-Double(policy.retentionDays) * 86_400))
        let candidates: [RetentionCandidate]
        do {
            candidates = try lifecycle.expiredCandidates(cutoff: cutoff, limit: queryLimit).map {
                RetentionCandidate(
                    id: $0.id, xmpPath: $0.xmpPath, backupPath: $0.backupPath)
            }
        } catch {
            result.errors.append(
                "METADATA_RETENTION_QUERY_FAILED: \(String(describing: error))")
            return result
        }

        // queryLimit 可能大于 limit（会话作用域下多取）：处理条数仍以 limit 封顶。
        var processed = 0
        for candidate in candidates {
            guard processed < limit else { break }
            let sessions: [(id: String, acked: Bool)]
            do {
                sessions = try linkedSessions(deliveryId: candidate.id)
            } catch {
                result.skipped += 1
                result.errors.append(
                    "METADATA_RETENTION_SESSIONS_FAILED: "
                        + "\(MetadataDeliveryService.pathToken(candidate.xmpPath)) "
                        + "reason=\(String(describing: error))")
                continue
            }
            // 会话作用域（P1-2）：与本会话无关的交付原样留给全局回收，不计 scanned。
            if let sessionId, !sessions.contains(where: { $0.id == sessionId }) {
                continue
            }
            processed += 1
            result.scanned += 1
            if !policy.ignoreReloadAck,
               coordinator.reloadAckGateEnabled,
               sessions.contains(where: { !$0.acked }) {
                // C1 仍显示旧值：备份是唯一还原点，跳过（手动"立即清理"才越过）。
                result.skipped += 1
                GatherLogger.log(
                    "trace=gc/deletions phase=retention skipped=reload-ack "
                        + "xmp=\(MetadataDeliveryService.pathToken(candidate.xmpPath))",
                    level: .info)
                continue
            }
            // photoPath 解析用会话上下文：作用域运行用本会话，全局运行沿用旧行为
            // （取排序后的第一个关联会话）。
            let resolvingSession = sessionId ?? sessions.first?.id ?? ""
            let summary = await coordinator.finalizeForRetention(
                xmpPath: candidate.xmpPath, sessionId: resolvingSession)
            result.deletedDeliveries += summary.deletedCount
            result.retainedDeliveries += summary.retainedCount
            result.skipped += summary.skippedCount
            result.errors.append(contentsOf: summary.errors)
        }
        return result
    }

    // MARK: - 3. 零 item 行

    private func purgeEmptyRows(
        limit: Int,
        queryLimit: Int,
        sessionId: String?,
        result: inout MetadataRetentionResult
    ) {
        let cutoff = isoString(now().addingTimeInterval(-Self.emptyRowMinimumAgeSeconds))
        let rows: [(id: Int64, xmpPath: String, backupPath: String)]
        do {
            rows = try lifecycle.emptyCandidates(cutoff: cutoff, limit: queryLimit).map {
                ($0.id, $0.xmpPath, $0.backupPath)
            }
        } catch {
            result.errors.append(
                "METADATA_RETENTION_EMPTY_QUERY_FAILED: \(String(describing: error))")
            return
        }
        var processed = 0
        for row in rows {
            guard processed < limit else { break }
            // 会话作用域（P1-2）：没有关联到本会话的空行留给全局回收。
            guard isInScope(
                deliveryId: row.id, sessionId: sessionId, errors: &result.errors) else { continue }
            processed += 1
            do {
                if try deleteRowIfEmpty(id: row.id, xmpPath: row.xmpPath) {
                    result.emptyRowsDeleted += 1
                    let freed = removeBackup(
                        xmpPath: row.xmpPath, backupPath: row.backupPath,
                        errors: &result.errors)
                    result.backupBytesFreed += freed
                } else {
                    result.skipped += 1
                }
            } catch {
                result.errors.append(
                    "METADATA_RETENTION_EMPTY_DELETE_FAILED: "
                        + "\(MetadataDeliveryService.pathToken(row.xmpPath)) "
                        + "reason=\(String(describing: error))")
            }
        }
    }

    // MARK: - 4. 文件已消失行

    private func purgeVanishedRows(
        limit: Int,
        queryLimit: Int,
        sessionId: String?,
        result: inout MetadataRetentionResult
    ) {
        let rows: [(id: Int64, xmpPath: String, backupPath: String)]
        do {
            rows = try lifecycle.vanishedCandidates(limit: queryLimit).map {
                ($0.id, $0.xmpPath, $0.backupPath)
            }
        } catch {
            result.errors.append(
                "METADATA_RETENTION_VANISHED_QUERY_FAILED: \(String(describing: error))")
            return
        }
        let fileManager = FileManager.default
        var processed = 0
        for row in rows {
            guard processed < limit else { break }
            // 会话作用域（P1-2）：别的会话的已消失行留给全局回收。
            guard isInScope(
                deliveryId: row.id, sessionId: sessionId, errors: &result.errors) else { continue }
            // 卷离线（父目录都不在）与文件真被删是两件事：只有后者才安全回收。
            let directory = (row.xmpPath as NSString).deletingLastPathComponent
            guard !directory.isEmpty,
                  fileManager.fileExists(atPath: directory),
                  !fileManager.fileExists(atPath: row.xmpPath) else { continue }
            // 只有真正进入删除段的候选才占本批配额（作用域外/卷离线的行不占）。
            processed += 1
            do {
                if try deleteRow(id: row.id, xmpPath: row.xmpPath) {
                    result.vanishedRowsDeleted += 1
                    let freed = removeBackup(
                        xmpPath: row.xmpPath, backupPath: row.backupPath,
                        errors: &result.errors)
                    result.backupBytesFreed += freed
                } else {
                    result.skipped += 1
                }
            } catch {
                result.errors.append(
                    "METADATA_RETENTION_VANISHED_DELETE_FAILED: "
                        + "\(MetadataDeliveryService.pathToken(row.xmpPath)) "
                        + "reason=\(String(describing: error))")
            }
        }
    }

    // MARK: - 5. 孤儿备份 / 崩溃残留临时文件

    /// 扫会话根目录第一层，删两类"DB 无引用且超过 24h"的文件：
    /// 1. 锚定通过的受控备份（`.gather-backup-`/`.gather-header-`）；
    /// 2. 崩溃残留的照片拷贝 `.gather-embedded-` 临时文件（C6）。
    ///
    /// 只应**全局**运行（会话作用域下 run 会跳过它）：扫描根是全体会话的
    /// source_path，而引用集合必须是全库的——按会话缩小引用集合会把其它会话仍在
    /// 用的备份判成孤儿。
    private func purgeOrphanBackups(result: inout MetadataRetentionResult) {
        let roots: [String]
        let referenced: Set<String>
        do {
            roots = try lifecycle.orphanRoots()
            referenced = try lifecycle.referencedBackupPaths()
        } catch {
            result.errors.append(
                "METADATA_RETENTION_ORPHAN_QUERY_FAILED: \(String(describing: error))")
            return
        }
        let fileManager = FileManager.default
        let cutoff = now().addingTimeInterval(-Self.orphanBackupMinimumAgeSeconds)
        for root in roots.sorted() {
            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: root)
            } catch {
                // 目录读不到（卷离线/权限）：跳过，不记错误噪声。
                continue
            }
            for name in entries {
                let full = TSPath.normalize((root as NSString).appendingPathComponent(name))
                // P1-4：锚定式判定。只有"名字能反推出 <xmp> 且通过 validate 的关系
                // 校验"的受控备份（.gather-backup-/.gather-header-）才进备份口径；
                // 崩溃残留的 .<photo>.gather-embedded-<uuid> 照片拷贝走独立口径
                // （同目录原照片仍在）。两种都不再按"名字含标记"盲删。
                let isBackup = DeliveryBackupPath.anchoredXMPPath(
                    forBackupName: name, inDirectory: root) != nil
                let isEmbeddedTemp = !isBackup
                    && DeliveryBackupPath.isRecoverableEmbeddedTemp(
                        name: name, inDirectory: root)
                guard isBackup || isEmbeddedTemp else { continue }
                // 备份在 DB 里有引用就绝不删；临时文件不进 deliveries.backup_path，
                // 这条判断对它恒为"无引用"（同一个删除守卫，不额外开岔路）。
                guard !referenced.contains(full) else { continue }
                let attributes: [FileAttributeKey: Any]?
                do {
                    attributes = try fileManager.attributesOfItem(atPath: full)
                } catch {
                    continue
                }
                guard let attributes,
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                do {
                    try fileManager.removeItem(atPath: full)
                    // 计数分开：备份是用户撤销点，临时文件只是崩溃残留（C6）。
                    if isBackup {
                        result.orphanBackupsDeleted += 1
                    } else {
                        result.embeddedTempsDeleted += 1
                    }
                    result.backupBytesFreed += size
                } catch {
                    let code = isBackup
                        ? "METADATA_RETENTION_ORPHAN_DELETE_FAILED: "
                        : "METADATA_RETENTION_EMBEDDED_TEMP_DELETE_FAILED: "
                    result.errors.append(
                        code + "\(MetadataDeliveryService.pathToken(full)) "
                            + "reason=\(String(describing: error))")
                }
            }
        }
    }

    // MARK: - DB 删除（零 item / 文件消失两条专用路径）

    /// 删除一条**零 item** 行：仓储在事务内重新确认"仍然没有 item"，避免与 upsert 竞态。
    private func deleteRowIfEmpty(id: Int64, xmpPath: String) throws -> Bool {
        try lifecycle.deleteRowIfEmpty(id: id, xmpPath: xmpPath)
    }

    /// 删除一条**文件已消失**行：文件检查在 Application，事务内复核 id/xmpPath。
    private func deleteRow(id: Int64, xmpPath: String) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: xmpPath) else { return false }
        return try lifecycle.deleteVanishedRow(id: id, xmpPath: xmpPath)
    }

    // MARK: - 备份删除（DB 提交之后）

    /// 删除受控备份文件；返回释放字节数。
    ///
    /// 必须在行删除**提交之后**调用（与 finalize 的顺序契约一致）：先删文件再删行，
    /// 一旦行删除失败就会留下指向已删文件的 backup_path（XMP_BACKUP_MISSING 永久失败）。
    private func removeBackup(
        xmpPath: String,
        backupPath: String,
        errors: inout [String]
    ) -> Int64 {
        guard !backupPath.isEmpty else { return 0 }
        let validated: String
        do {
            validated = try DeliveryBackupPath.validate(xmpPath: xmpPath, backupPath: backupPath)
        } catch {
            errors.append(
                "XMP_FINALIZE_BACKUP_PATH_INVALID: "
                    + "\(MetadataDeliveryService.pathToken(xmpPath)) "
                    + "reason=\(String(describing: error))")
            return 0
        }
        let attributes: [FileAttributeKey: Any]?
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: validated)
        } catch {
            // 不存在就读不到属性：下面的存在性判断会让它返回 0（幂等）。
            attributes = nil
        }
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: validated) else { return 0 }
        do {
            try FileManager.default.removeItem(atPath: validated)
            return size
        } catch {
            errors.append(
                "XMP_FINALIZE_BACKUP_CLEANUP_FAILED: "
                    + "\(MetadataDeliveryService.pathToken(xmpPath)) "
                    + "reason=\(String(describing: error))")
            return 0
        }
    }

    // MARK: - 会话读取

    private func linkedSessions(deliveryId: Int64) throws -> [(id: String, acked: Bool)] {
        try lifecycle.linkedSessions(deliveryId: deliveryId)
    }
}
