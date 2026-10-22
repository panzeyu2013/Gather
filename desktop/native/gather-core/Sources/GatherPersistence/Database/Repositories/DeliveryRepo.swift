// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo.swift
// Cut 2 / S2：统一 delivery 模型的持久化层（draft §5 / D-013）。
//
// 设计要点：
// 1. **状态机唯一入口**：所有状态写入都先经 DeliveryState.canTransition 校验；
//    非法迁移抛 DeliveryRepoError.illegalTransition，不静默改写。
// 2. **CAS 写入**：每次状态迁移都是单条原子 UPDATE，带
//    WHERE xmp_path = ? AND revision = ? AND status IN (<迁移表允许的来源态>)。
//    返回 nil 表示 CAS 失败（revision 过期或状态已被并发迁移），调用方必须重读后重试，
//    不得把 nil 当成功。
// 3. **revision 语义**：revision 是「输入版本号」（新输入 / 新基线推进），状态迁移**不改**
//    revision——否则 cleanup 的 DELETE ... WHERE id = ? AND revision = ? 守卫会失效；
//    迁移的并发安全由 status 集合 + revision 双守卫保证。
// 4. **显式列 + 按列名映射**：所有 SELECT 列出列名（禁止 SELECT *）；行映射按
//    (列名, 值) 字典取值，不依赖 DDL 物理列序（draft §8 R1 / D-013 R1）。
// 5. 删除出口：cleanup（恢复备份）与 finalize（丢弃备份）共用
//    deleteSyncedDelivery（S5c-2b-1），单事务 + revision/status/跨会话确认守卫；
//    sessions.writeback_status 的同步仍不做（D-021，会话状态由聚合派生）。
// 6. **writing 租约（P1-2）**：执行器走 claimWriting（同 owner 续租 / heartbeat 过期
//    抢占 / 他人未过期 leaseHeld），markWriting 保留为无租约的底层迁移供短事务写者
//    使用；renewWriting 只刷新 heartbeat，不改 attempt_count。

import Foundation
import GatherProtocol

/// delivery 仓储错误。非法状态迁移是本文件唯一允许抛出的「状态机拒绝」。
public enum DeliveryRepoError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 迁移表拒绝（含 item 迁移，from/to 以 "item:" 前缀区分）。
    case illegalTransition(xmpPath: String, from: String, to: String)
    /// 行不存在（写入口必须显式失败，不能静默 no-op）。
    case rowNotFound(xmpPath: String)
    /// SELECT 缺少必需列（显式列清单与行映射器漂移）。
    case missingColumn(String)
    /// 写入成功但读回缺失（不得谎报成功）。
    case writeNotPersisted(String)
    /// 调用参数非法（空路径 / 负 revision / 缺 module）。
    case invalidArgument(String)
    /// writing 租约被另一个 owner 持有且尚未过期（抢占拒绝）。
    case leaseHeld(xmpPath: String, leaseOwner: String, heartbeatAt: String)
    /// 提交 written 时租约已不属于本 owner（被接管 / 被新输入重开 / 已收敛）。
    /// 行必须原样保留：调用方只能重读并放弃本轮收敛，不得覆盖新基线。
    case leaseLost(xmpPath: String, leaseOwner: String, currentOwner: String, status: String)

    public var code: String {
        switch self {
        case .illegalTransition: return "DELIVERY_ILLEGAL_TRANSITION"
        case .rowNotFound: return "DELIVERY_NOT_FOUND"
        case .missingColumn: return "DELIVERY_MISSING_COLUMN"
        case .writeNotPersisted: return "DELIVERY_NOT_PERSISTED"
        case .invalidArgument: return "DELIVERY_INVALID_ARGUMENT"
        case .leaseHeld: return "DELIVERY_LEASE_HELD"
        case .leaseLost: return "DELIVERY_LEASE_LOST"
        }
    }

    public var description: String {
        switch self {
        case .illegalTransition(let path, let from, let to):
            return "\(code): \(path) \(from) -> \(to)"
        case .rowNotFound(let path):
            return "\(code): \(path)"
        case .missingColumn(let name):
            return "\(code): \(name)"
        case .writeNotPersisted(let key):
            return "\(code): \(key)"
        case .invalidArgument(let message):
            return "\(code): \(message)"
        case .leaseHeld(let xmpPath, let leaseOwner, let heartbeatAt):
            return "\(code): \(xmpPath) owner=\(leaseOwner) heartbeat=\(heartbeatAt)"
        case .leaseLost(let xmpPath, let leaseOwner, let currentOwner, let status):
            return "\(code): \(xmpPath) owner=\(leaseOwner) current=\(currentOwner) status=\(status)"
        }
    }

    public var errorDescription: String? { description }
}

/// confirm 的事务内门禁失败（P1-3）。
///
/// 门禁读（完整性 + 可选的 reload-ack）与 `confirmed_at`/状态更新在**同一个**
/// `connection.transaction` 内：抛错会回滚整个事务，不会留下「已确认链接但交付
/// 仍 pending」的半套结果。与 `DeliveryRepoError` 分开，因为这是确认策略而非
/// 行级 CAS；上层（DeliveryCoordinator）负责映射回旧错误码。
public enum DeliveryConfirmGateError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// 目标作用域内仍有 pending/writing/failed/conflict 的交付或 item。
    case incomplete(blockers: [String])
    /// Capture One 尚未确认重载（requireReloadAck=true 时）。
    case reloadNotAcknowledged(sessionId: String)

    public var code: String {
        switch self {
        case .incomplete: return "XMP_CONFIRM_INCOMPLETE"
        case .reloadNotAcknowledged: return "XMP_CONFIRM_REQUIRES_SYNC"
        }
    }

    public var description: String {
        switch self {
        case .incomplete(let blockers):
            return "\(code): " + blockers.joined(separator: ",")
        case .reloadNotAcknowledged(let sessionId):
            return "\(code): \(sessionId)"
        }
    }

    public var errorDescription: String? { description }
}

/// 显式列清单 → (列名, 值) 映射的唯一实现（行映射不依赖列序）。
private enum DeliveryColumnMap {
    static func index(columns: [String], row: DBRow, required: [String]) throws -> [String: DBValue] {
        guard columns.count == row.count else {
            throw DeliveryRepoError.invalidArgument("列名与行宽不一致: \(columns.count) vs \(row.count)")
        }
        var map: [String: DBValue] = [:]
        for (index, name) in columns.enumerated() {
            map[name] = row[index]
        }
        for name in required where map[name] == nil {
            throw DeliveryRepoError.missingColumn(name)
        }
        return map
    }

    static func text(_ map: [String: DBValue], _ name: String) -> String {
        map[name]?.textValue ?? ""
    }

    static func int(_ map: [String: DBValue], _ name: String) -> Int64 {
        map[name]?.intValue ?? 0
    }
}

/// deliveries 表行（14 列，与 SchemaV1 §5.2 一致）。
///
/// 注意：columnNames 是仓储 SELECT 的显式列清单，也是行映射器的键；
/// 二者始终同源，且与表的物理列序无关（测试用乱序列清单验证）。
public struct DeliveryRow: Sendable, Equatable {
    public let id: Int64
    public let xmpPath: String
    public let photoPath: String
    public let status: String
    public let revision: Int64
    public let baseFingerprint: String
    public let baseValuesJSON: String
    public let backupPath: String
    public let errorMessage: String
    public let attemptCount: Int64
    public let leaseOwner: String
    public let heartbeatAt: String
    public let createdAt: String
    public let updatedAt: String

    /// 显式列清单（唯一来源；SQL 与映射器都由它派生）。
    public static let columnNames: [String] = [
        "id", "xmp_path", "photo_path", "status", "revision", "base_fingerprint",
        "base_values_json", "backup_path", "error_message", "attempt_count",
        "lease_owner", "heartbeat_at", "created_at", "updated_at",
    ]

    static var selectList: String { columnNames.joined(separator: ", ") }

    public init(columns: [String], row: DBRow) throws {
        let map = try DeliveryColumnMap.index(columns: columns, row: row, required: Self.columnNames)
        id = DeliveryColumnMap.int(map, "id")
        xmpPath = DeliveryColumnMap.text(map, "xmp_path")
        photoPath = DeliveryColumnMap.text(map, "photo_path")
        status = DeliveryColumnMap.text(map, "status")
        revision = DeliveryColumnMap.int(map, "revision")
        baseFingerprint = DeliveryColumnMap.text(map, "base_fingerprint")
        baseValuesJSON = DeliveryColumnMap.text(map, "base_values_json")
        backupPath = DeliveryColumnMap.text(map, "backup_path")
        errorMessage = DeliveryColumnMap.text(map, "error_message")
        attemptCount = DeliveryColumnMap.int(map, "attempt_count")
        leaseOwner = DeliveryColumnMap.text(map, "lease_owner")
        heartbeatAt = DeliveryColumnMap.text(map, "heartbeat_at")
        createdAt = DeliveryColumnMap.text(map, "created_at")
        updatedAt = DeliveryColumnMap.text(map, "updated_at")
    }

    public var typedStatus: DeliveryStatus? { DeliveryStatus(rawValue: status) }

    public var baseValues: JSONValue {
        (try? JSONValue.parse(baseValuesJSON)) ?? .object([:])
    }
}

/// delivery_items 表行（11 列 + JOIN 得到的 delivery.xmp_path）。
public struct DeliveryItemRow: Sendable, Equatable {
    public let id: Int64
    public let deliveryId: Int64
    public let photoId: String
    public let module: String
    public let attributesJSON: String
    public let keywords: String
    public let status: String
    public let errorMessage: String
    public let attemptCount: Int64
    public let createdAt: String
    public let updatedAt: String
    /// 派生于 deliveries.xmp_path（显式 JOIN 列，不是 delivery_items 的物理列）。
    public let xmpPath: String

    /// delivery_items 的物理列（SELECT 中带 di. 前缀）。
    public static let tableColumnNames: [String] = [
        "id", "delivery_id", "photo_id", "module", "attributes_json", "keywords",
        "status", "error_message", "attempt_count", "created_at", "updated_at",
    ]

    /// 映射器键：物理列 + 派生列。
    public static let columnNames: [String] = tableColumnNames + ["xmp_path"]

    static var selectList: String {
        tableColumnNames.map { "di." + $0 }.joined(separator: ", ") + ", d.xmp_path"
    }

    public init(columns: [String], row: DBRow) throws {
        let map = try DeliveryColumnMap.index(columns: columns, row: row, required: Self.columnNames)
        id = DeliveryColumnMap.int(map, "id")
        deliveryId = DeliveryColumnMap.int(map, "delivery_id")
        photoId = DeliveryColumnMap.text(map, "photo_id")
        module = DeliveryColumnMap.text(map, "module")
        attributesJSON = DeliveryColumnMap.text(map, "attributes_json")
        keywords = DeliveryColumnMap.text(map, "keywords")
        status = DeliveryColumnMap.text(map, "status")
        errorMessage = DeliveryColumnMap.text(map, "error_message")
        attemptCount = DeliveryColumnMap.int(map, "attempt_count")
        createdAt = DeliveryColumnMap.text(map, "created_at")
        updatedAt = DeliveryColumnMap.text(map, "updated_at")
        xmpPath = DeliveryColumnMap.text(map, "xmp_path")
    }

    public var typedStatus: DeliveryItemStatus? { DeliveryItemStatus(rawValue: status) }
    public var typedModule: DeliveryModule? { DeliveryModule(rawValue: module) }

    public var keywordList: [String] {
        guard case .array(let values) = (try? JSONValue.parse(keywords)) ?? .null else { return [] }
        return values.compactMap(\.stringValue)
    }

    public var attributes: [String: JSONValue] {
        ((try? JSONValue.parse(attributesJSON)) ?? .object([:])).objectValue ?? [:]
    }
}

/// deliveries / delivery_items 仓储（本批只做持久化，不接线服务层）。
public final class DeliveryRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 路径口径

    /// xmp 路径唯一归一化：只做路径标准化（折叠 ./..、重复斜杠），
    /// **不做** photo→sidecar 猜测（旧 outbox 的隐式转换是双写期的歧义来源）。
    private func normalizedPath(_ xmpPath: String) throws -> String {
        let path = TSPath.normalize(xmpPath)
        guard !path.isEmpty else { throw DeliveryRepoError.invalidArgument("xmpPath 不能为空") }
        return path
    }

    // MARK: - 创建 / 读取

    /// 幂等入队：xmp_path 已存在时**原样返回**（不覆盖 photo_path/base 基线/revision）。
    ///
    /// 为什么不覆盖：改名迁移（AssetRepo.relocateMetadataState）与「新输入」是两条显式路径，
    /// 由后续 S3 的 mergeInput/bumpRevision 承担；隐式覆盖会让 revision 的 CAS 语义失效。
    @discardableResult
    public func createOrGet(
        xmpPath: String,
        photoPath: String,
        revision: Int64 = 0,
        baseFingerprint: String = "",
        baseValues: JSONValue = .object([:])
    ) throws -> DeliveryRow {
        let path = try normalizedPath(xmpPath)
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
        let now = nowISOString()
        let baseJSON = try JSONValue.stringify(baseValues)
        try connection.transaction {
            _ = try connection.prepare("""
                INSERT INTO deliveries (
                  xmp_path, photo_path, status, revision, base_fingerprint,
                  base_values_json, created_at, updated_at
                ) VALUES (?, ?, 'pending', ?, ?, ?, ?, ?)
                ON CONFLICT(xmp_path) DO NOTHING
                """).run([
                    .text(path), .text(photoPath), .int(revision),
                    .text(baseFingerprint), .text(baseJSON), .text(now), .text(now),
                ])
        }
        guard let row = try get(path) else {
            throw DeliveryRepoError.writeNotPersisted(path)
        }
        return row
    }

    public func get(_ xmpPath: String) throws -> DeliveryRow? {
        let path = try normalizedPath(xmpPath)
        guard let row = try connection.prepare("""
            SELECT \(DeliveryRow.selectList) FROM deliveries WHERE xmp_path = ?
            """).get([.text(path)]) else { return nil }
        return try DeliveryRow(columns: DeliveryRow.columnNames, row: row)
    }

    /// 按 xmp_path 批量读取交付行（一次 IN 查询替代逐行 get 的 N+1）。
    ///
    /// 键为归一化路径；不存在的路径不出现在返回值里（调用方自行判定缺失）。
    /// 分块 400 与旧 WritebackRepo 的批量口径一致，避免超过 SQLite 变量上限。
    public func getMany(xmpPaths: [String]) throws -> [String: DeliveryRow] {
        var map: [String: DeliveryRow] = [:]
        let paths = Array(Set(xmpPaths.map { TSPath.normalize($0) })).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return map }
        for chunkStart in stride(from: 0, to: paths.count, by: 400) {
            let chunk = paths[chunkStart..<min(chunkStart + 400, paths.count)]
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT \(DeliveryRow.selectList) FROM deliveries
                WHERE xmp_path IN (\(placeholders))
                """).query(chunk.map { DBValue.text($0) })
            for row in rows {
                let delivery = try DeliveryRow(columns: DeliveryRow.columnNames, row: row)
                map[delivery.xmpPath] = delivery
            }
        }
        return map
    }

    // MARK: - 状态迁移（CAS）

    /// pending/failed/conflict → writing（租约起点；attempt_count + 1）。
    ///
    /// P2 收口：生产代码只用 `claimWriting`（带租约）；本方法只为既有测试/
    /// 夹具保留 "writing + 空 lease_owner" 的构造能力，已 deprecated。
    /// 生产新增调用必须走 claimWriting（owner/TTL/抢占语义在那里）。
    /// 说明：未直接降为 internal，是因为 gather-app 测试（跨包、非 @testable）
    /// 仍用它构造夹具；保留 deprecated public 以避免跨包编译破坏。
    @available(*, deprecated, message: "生产已无调用；请使用 claimWriting（租约 owner/TTL）")
    @discardableResult
    public func markWriting(
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

    // MARK: - 交付项

    /// 逐 (delivery, photo, module) upsert。UNIQUE 冲突时更新 attributes/keywords/status。
    /// 已存在行仍经迁移表校验（synced → pending 是「新输入重新打开」的合法路径）。
    @discardableResult
    public func upsertItem(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule,
        attributes: [String: JSONValue] = [:],
        keywords: [String] = [],
        status: DeliveryItemStatus = .pending,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow {
        let path = try normalizedPath(xmpPath)
        let attributesJSON = try JSONValue.stringify(.object(attributes))
        let keywordsJSON = try JSONValue.stringify(.array(keywords.map { .string($0) }))
        let now = nowISOString()
        return try connection.transaction {
            guard let delivery = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            if let existing = try itemRow(deliveryId: delivery.id, photoId: photoId, module: module) {
                guard let current = existing.typedStatus else {
                    throw DeliveryRepoError.illegalTransition(
                        xmpPath: path, from: "item:\(existing.status)", to: "item:\(status.rawValue)")
                }
                guard current.canTransition(to: status) else {
                    throw DeliveryRepoError.illegalTransition(
                        xmpPath: path, from: "item:\(current.rawValue)", to: "item:\(status.rawValue)")
                }
            }
            _ = try connection.prepare("""
                INSERT INTO delivery_items (
                  delivery_id, photo_id, module, attributes_json, keywords,
                  status, error_message, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(delivery_id, photo_id, module) DO UPDATE SET
                  attributes_json = excluded.attributes_json,
                  keywords = excluded.keywords,
                  status = excluded.status,
                  error_message = excluded.error_message,
                  updated_at = excluded.updated_at
                """).run([
                    .int(delivery.id), .text(photoId), .text(module.rawValue),
                    .text(attributesJSON), .text(keywordsJSON), .text(status.rawValue),
                    .text(errorMessage), .text(now), .text(now),
                ])
            guard let row = try itemRow(deliveryId: delivery.id, photoId: photoId, module: module) else {
                throw DeliveryRepoError.writeNotPersisted("\(path)#\(photoId)#\(module.rawValue)")
            }
            return row
        }
    }

    /// 会话视角的 item 列表：delivery_items 本身不带 session_id，必须经 photos.session_id 关联。
    public func listItems(
        sessionId: String,
        module: DeliveryModule? = nil,
        status: DeliveryItemStatus? = nil
    ) throws -> [DeliveryItemRow] {
        var sql = """
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            JOIN photos p ON p.id = di.photo_id
            WHERE p.session_id = ?
            """
        var values: [DBValue?] = [.text(sessionId)]
        if let module {
            sql += " AND di.module = ?"
            values.append(.text(module.rawValue))
        }
        if let status {
            sql += " AND di.status = ?"
            values.append(.text(status.rawValue))
        }
        sql += " ORDER BY di.id ASC"
        let rows = try connection.prepare(sql).query(values)
        return try rows.map { try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: $0) }
    }

    /// 按主键读取单条交付项（execute / persist 的行映射入口）。
    public func item(id: Int64) throws -> DeliveryItemRow? {
        try itemRow(id: id)
    }

    /// 交付项状态迁移（**唯一入口**：先过 DeliveryItemStatus.canTransition，再 CAS）。
    ///
    /// 与 deliveries 的状态迁移同一纪律：
    /// - 非法迁移抛 DeliveryRepoError.illegalTransition（from/to 带 "item:" 前缀）；
    /// - CAS 带「迁移表允许的来源态」守卫，返回 nil 表示并发迁移抢先（不是错误）；
    /// - attempt_count + 1 / updated_at 刷新，对应旧 writeback_items.updateStatus。
    @discardableResult
    public func markItem(
        itemId: Int64,
        status: DeliveryItemStatus,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow? {
        guard let current = try itemRow(id: itemId) else {
            throw DeliveryRepoError.writeNotPersisted("delivery_item#\(itemId)")
        }
        guard let typed = current.typedStatus else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: current.xmpPath, from: "item:\(current.status)", to: "item:\(status.rawValue)")
        }
        guard typed.canTransition(to: status) else {
            throw DeliveryRepoError.illegalTransition(
                xmpPath: current.xmpPath, from: "item:\(typed.rawValue)", to: "item:\(status.rawValue)")
        }
        let changed = try connection.prepare("""
            UPDATE delivery_items
            SET status = ?, error_message = ?, attempt_count = attempt_count + 1, updated_at = ?
            WHERE id = ? AND status IN (\(Self.allowedItemFromSQL(for: status)))
            """).run([
                .text(status.rawValue), .text(errorMessage), .text(nowISOString()), .int(itemId),
            ])
        guard changed == 1 else { return nil }
        return try itemRow(id: itemId)
    }

    /// 迁移表反向查询（item 版）：所有能到达 target 的来源态。
    private static func allowedItemFromSQL(for target: DeliveryItemStatus) -> String {
        DeliveryItemStatus.allCases
            .filter { $0.canTransition(to: target) }
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
    }

    /// 批量更新 delivery_items.attributes_json（persistAttributes 的唯一写入口）。
    ///
    /// 单事务；任一行不存在即整批回滚并抛 writeNotPersisted——写入口不得静默 no-op
    /// （旧 updateAttributesMany 的 0 行更新会让"属性已持久化"变成谎言）。
    public func updateItemAttributes(
        _ updates: [(itemId: Int64, attributes: [String: JSONValue])]
    ) throws {
        guard !updates.isEmpty else { return }
        let now = nowISOString()
        try connection.transaction {
            let statement = try connection.prepare(
                "UPDATE delivery_items SET attributes_json = ?, updated_at = ? WHERE id = ?")
            for update in updates {
                let json = try JSONValue.stringify(.object(update.attributes))
                let changed = try statement.run([.text(json), .text(now), .int(update.itemId)])
                guard changed == 1 else {
                    throw DeliveryRepoError.writeNotPersisted("delivery_item#\(update.itemId)")
                }
            }
        }
    }

    /// 批量更新 delivery_items.keywords（persistKeywords 的唯一写入口）。
    /// 事务语义与 updateItemAttributes 一致。
    public func updateItemKeywords(_ updates: [(itemId: Int64, keywords: [String])]) throws {
        guard !updates.isEmpty else { return }
        let now = nowISOString()
        try connection.transaction {
            let statement = try connection.prepare(
                "UPDATE delivery_items SET keywords = ?, updated_at = ? WHERE id = ?")
            for update in updates {
                let json = try JSONValue.stringify(.array(update.keywords.map { .string($0) }))
                let changed = try statement.run([.text(json), .text(now), .int(update.itemId)])
                guard changed == 1 else {
                    throw DeliveryRepoError.writeNotPersisted("delivery_item#\(update.itemId)")
                }
            }
        }
    }

    // MARK: - 手动元数据队列（S5c-2b-3b-2b-2）

    /// 按 (xmp_path, photo, module) 读取单条交付项。
    ///
    /// 手动 rating/label/keywords 的队列要做「读取现有 item → 合并字段 → 写回」，
    /// 读入口必须与 UNIQUE(delivery_id, photo_id, module) 同一口径，不能借
    /// listItems 全表扫（会话内 N+1）。
    public func item(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule
    ) throws -> DeliveryItemRow? {
        guard let delivery = try get(xmpPath) else { return nil }
        return try itemRow(deliveryId: delivery.id, photoId: photoId, module: module)
    }

    /// 交付项字段级合并（旧 outbox mergePatch 的字段语义，S5c-2b-3b-2b-2）。
    ///
    /// - attributes 只覆盖同名字段，未提及字段保留（rating/label 各自独立）；
    /// - keywords 传 nil 表示「本次不动关键词」，传数组表示整体替换；
    /// - status 经迁移表校验（synced → pending 是「新输入重新打开」的合法路径）。
    ///
    /// 读-合并-写在**一个事务**内完成：旧实现由仓库保证同一路径串行，
    /// 否则两个并发入队会互相覆盖对方的字段。
    @discardableResult
    public func mergeItem(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule,
        attributes: [String: JSONValue] = [:],
        keywords: [String]? = nil,
        status: DeliveryItemStatus = .pending,
        errorMessage: String = ""
    ) throws -> DeliveryItemRow {
        let path = try normalizedPath(xmpPath)
        return try connection.transaction {
            guard let delivery = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            let existing = try itemRow(deliveryId: delivery.id, photoId: photoId, module: module)
            var merged = existing?.attributes ?? [:]
            for (key, value) in attributes { merged[key] = value }
            return try upsertItem(
                xmpPath: path,
                photoId: photoId,
                module: module,
                attributes: merged,
                keywords: keywords ?? existing?.keywordList ?? [],
                status: status,
                errorMessage: errorMessage
            )
        }
    }

    /// 手动元数据入队的原子入口（P1-3）：开行（mergeInput）+ 合并 item + 链接会话
    /// 收进**一个** connection.transaction。
    ///
    /// 三步原先由 MetadataMutationService 分别调用、各自提交：中间任一步失败会留下
    /// 「revision 已 +1、status=pending，但没有任何 item/link」的幽灵交付（永久阻断
    /// 该侧车其它模块 confirm，且无 item 可执行），或 linkSession 被 FK 拒绝后留下
    /// 孤儿 pending item（会话/UI/cleanup 都看不到）。原子化后任何一步失败整体回滚：
    /// revision 不推进、不产生 delivery_items / delivery_sessions 行。
    ///
    /// 参数语义与各步完全一致（attributes/keywords 由服务层算好；keywords=nil 表示
    /// 本次不动词表；入队状态固定 pending）。返回提交后的交付行。
    @discardableResult
    public func applyMetadataMutation(
        xmpPath: String,
        photoPath: String,
        photoId: String,
        sessionId: String,
        attributes: [String: JSONValue] = [:],
        keywords: [String]? = nil
    ) throws -> DeliveryRow {
        let path = try normalizedPath(xmpPath)
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        return try connection.transaction {
            _ = try openDeliveryForInput(xmpPath: path, photoPath: photoPath)
            _ = try mergeItem(
                xmpPath: path,
                photoId: photoId,
                module: .metadata,
                attributes: attributes,
                keywords: keywords,
                status: .pending)
            // 链接会话：conflicts 按会话反查交付（旧 metadata_outbox_sessions 的等价物）。
            // session 不存在时 FK 拒绝 → 外层事务把前两步一并回滚。
            _ = try linkSession(xmpPath: path, sessionId: sessionId)
            guard let row = try get(path) else {
                throw DeliveryRepoError.writeNotPersisted(path)
            }
            return row
        }
    }

    /// 「新输入」重开交付行（原 MetadataMutationService.openDelivery 的原子版）。
    ///
    /// - 行不存在 → 新建（pending，revision 1 = 首个输入版本号）；
    /// - cleaned 是审计终态（D-031），不可重开：显式失败，不静默丢弃用户输入；
    /// - 其余状态一律 revision + 1 回到 pending，**基线保持不变**
    ///   （真实基线由执行器写盘后回读落库，本层不猜）。
    /// - CAS 失配重读一次再推（单连接事务内通常不会发生，保留与服务层旧语义一致）。
    private func openDeliveryForInput(xmpPath: String, photoPath: String) throws -> DeliveryRow {
        for _ in 0..<2 {
            guard let current = try get(xmpPath) else {
                // 首次输入 = revision 1（旧 outbox mergePatch 对新建行的同一口径）。
                return try createOrGet(xmpPath: xmpPath, photoPath: photoPath, revision: 1)
            }
            guard let typed = current.typedStatus else {
                throw DeliveryRepoError.illegalTransition(
                    xmpPath: current.xmpPath,
                    from: current.status,
                    to: DeliveryStatus.pending.rawValue)
            }
            guard typed != .cleaned else {
                throw DeliveryRepoError.illegalTransition(
                    xmpPath: current.xmpPath,
                    from: typed.rawValue,
                    to: DeliveryStatus.pending.rawValue)
            }
            if let merged = try mergeInput(
                xmpPath: current.xmpPath,
                photoPath: current.photoPath.isEmpty ? photoPath : current.photoPath,
                expectedRevision: current.revision,
                newRevision: current.revision + 1,
                baseFingerprint: current.baseFingerprint,
                baseValues: current.baseValues
            ) {
                return merged
            }
        }
        throw DeliveryRepoError.writeNotPersisted(xmpPath)
    }

    /// 某交付下的全部交付项（按 id 升序 = 入队顺序；conflicts 投影用）。
    public func items(deliveryId: Int64) throws -> [DeliveryItemRow] {
        let rows = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.delivery_id = ?
            ORDER BY di.id ASC
            """).query([.int(deliveryId)])
        return try rows.map { try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: $0) }
    }

    private func itemRow(
        deliveryId: Int64,
        photoId: String,
        module: DeliveryModule
    ) throws -> DeliveryItemRow? {
        guard let row = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.delivery_id = ? AND di.photo_id = ? AND di.module = ?
            """).get([.int(deliveryId), .text(photoId), .text(module.rawValue)]) else {
            return nil
        }
        return try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: row)
    }

    private func itemRow(id: Int64) throws -> DeliveryItemRow? {
        guard let row = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.id = ?
            """).get([.int(id)]) else {
            return nil
        }
        return try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: row)
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
        leaseOwner: String = ""
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
        leaseOwner: String = ""
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

    // MARK: - 冲突 / 孤儿（S5c-2b-3b-2b-2：旧 outbox 查询的交付等价物）

    /// 会话视角的 conflict 交付（旧 metadata_outbox 的 status='conflict' 行等价物）。
    ///
    /// 冲突是**交付级**事实（一个侧车文件一个状态），按 delivery_sessions 反查会话，
    /// 与旧 getBySession(sessionId).filter(status == conflict) 同一口径。
    public func conflictDeliveries(sessionId: String) throws -> [DeliveryRow] {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        // 交付行显式列必须带 d. 前缀：delivery_sessions 也有 created_at/updated_at。
        let selectList = DeliveryRow.columnNames.map { "d." + $0 }.joined(separator: ", ")
        let rows = try connection.prepare("""
            SELECT \(selectList)
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE ds.session_id = ? AND d.status = ?
            ORDER BY d.updated_at DESC, d.id ASC
            """).query([.text(sessionId), .text(DeliveryStatus.conflict.rawValue)])
        return try rows.map { try DeliveryRow(columns: DeliveryRow.columnNames, row: $0) }
    }

    /// 孤儿交付：没有任何 delivery_sessions 关联（旧 getOrphans 的同一判据）。
    ///
    /// 这类行不再有会话能确认/清理，只能由 metadata.orphans 处置（keep/restore/retry）。
    public func orphanDeliveries() throws -> [DeliveryRow] {
        let rows = try connection.prepare("""
            SELECT \(DeliveryRow.selectList) FROM deliveries
            WHERE NOT EXISTS (
              SELECT 1 FROM delivery_sessions ds WHERE ds.delivery_id = deliveries.id
            )
            ORDER BY updated_at DESC, id ASC
            """).query()
        return try rows.map { try DeliveryRow(columns: DeliveryRow.columnNames, row: $0) }
    }

    /// 删除孤儿交付：单事务、revision CAS，且执行删除时仍无会话关联。
    ///
    /// 返回 false 只表示「状态已漂移」（并发改写/被重新链接），调用方重读列表即可，
    /// 不得当作成功；真正删不掉时抛 writeNotPersisted 回滚子行删除。
    @discardableResult
    public func deleteOrphanDelivery(xmpPath: String, revision: Int64) throws -> Bool {
        let path = try normalizedPath(xmpPath)
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
        return try connection.transaction {
            guard let current = try get(path), current.revision == revision else { return false }
            let links = try connection.prepare("""
                SELECT COUNT(*) FROM delivery_sessions WHERE delivery_id = ?
                """).get([.int(current.id)])?[0].intValue ?? 0
            guard links == 0 else { return false }
            _ = try connection.prepare("DELETE FROM delivery_items WHERE delivery_id = ?")
                .run([.int(current.id)])
            let removed = try connection.prepare("""
                DELETE FROM deliveries WHERE id = ? AND revision = ?
                """).run([.int(current.id), .int(revision)])
            guard removed == 1 else {
                // 事务内已校验仍删不掉：宁可抛错回滚子行删除，也不留半删状态。
                throw DeliveryRepoError.writeNotPersisted("delivery#\(current.id)")
            }
            return true
        }
    }

    /// 旧 MetadataSyncSummary 投影（LiveMetadataAPI.resolveConflict 的返回形状）。
    /// 与 DeliveryCoordinator.metadataSummary 共用 DeliverySummaryQuery 的唯一口径。
    public func metadataSummary(
        sessionId: String,
        module: DeliveryModule? = nil
    ) throws -> MetadataSyncSummary {
        try DeliverySummaryQuery(connection: connection)
            .metadataSummary(sessionId: sessionId, module: module)
    }

    /// 把交付链接到会话（delivery_sessions 的 ONLY 写入路径）。
    ///
    /// 语义：
    /// - 幂等（UNIQUE(delivery_id, session_id)）：新链接以 confirmed_at='' 插入，
    ///   不继承该交付上任何旧确认；重复链接把**该会话**的 confirmed_at 重置为 ''。
    ///   其他会话的确认只由新输入（mergeInput）统一失效，链接本身不替别人清确认。
    /// - **不改 delivery.status**：链接本身不是输入变更；synced 行被新会话链接后仍是 synced，
    ///   但新链接的 confirmed_at=''，交付若仍停在 written，任何会话的 confirm 都不会翻 synced。
    /// - session 不存在时由 FK 显式拒绝（不静默丢链接）。
    @discardableResult
    public func linkSession(xmpPath: String, sessionId: String) throws -> DeliveryRow {
        let path = try normalizedPath(xmpPath)
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        let now = nowISOString()
        return try connection.transaction {
            guard let delivery = try get(path) else {
                throw DeliveryRepoError.rowNotFound(xmpPath: path)
            }
            _ = try connection.prepare("""
                INSERT INTO delivery_sessions (delivery_id, session_id, confirmed_at, created_at)
                VALUES (?, ?, '', ?)
                ON CONFLICT(delivery_id, session_id) DO UPDATE SET confirmed_at = ''
                """).run([.int(delivery.id), .text(sessionId), .text(now)])
            guard let row = try get(path) else {
                throw DeliveryRepoError.writeNotPersisted(path)
            }
            return row
        }
    }

    // MARK: - 交付项删除

    /// 删除指定交付下、给定模块/状态的 items（默认只删 pending+failed，对齐旧 discard 语义）。
    /// 返回实际删除行数。
    @discardableResult
    public func deleteItems(
        xmpPath: String,
        module: DeliveryModule? = nil,
        statuses: Set<DeliveryItemStatus> = [.pending, .failed]
    ) throws -> Int {
        _ = try normalizedPath(xmpPath)
        guard !statuses.isEmpty else { return 0 }
        return try connection.transaction {
            try deleteItemsInTransaction(
                xmpPath: xmpPath, module: module, statuses: statuses)
        }
    }

    /// 事务内变体（WP2b）：调用方已持有 connection.transaction 时使用，不另开 savepoint。
    ///
    /// 目前唯一调用方是 DeliveryDBPhase 的 retainForeign 分支：只清本模块 item
    /// 与 intent.finish 必须同事务，避免「item 已删、intent 未收尾」。
    @discardableResult
    public func deleteItemsInTransaction(
        xmpPath: String,
        module: DeliveryModule? = nil,
        statuses: Set<DeliveryItemStatus> = [.pending, .failed]
    ) throws -> Int {
        let path = try normalizedPath(xmpPath)
        guard !statuses.isEmpty else { return 0 }
        guard let delivery = try get(path) else {
            throw DeliveryRepoError.rowNotFound(xmpPath: path)
        }
        var sql = "DELETE FROM delivery_items WHERE delivery_id = ?"
        var values: [DBValue?] = [.int(delivery.id)]
        if let module {
            sql += " AND module = ?"
            values.append(.text(module.rawValue))
        }
        let placeholders = statuses
            .sorted { $0.rawValue < $1.rawValue }
            .map { _ in "?" }
            .joined(separator: ", ")
        sql += " AND status IN (\(placeholders))"
        values.append(contentsOf: statuses
            .sorted { $0.rawValue < $1.rawValue }
            .map { DBValue.text($0.rawValue) })
        return try connection.prepare(sql).run(values)
    }

    // MARK: - 终态删除（cleanup / finalize 共用）

    /// 删除已确认交付的结果。cleanup 的 replay 与 finalize 的 dropWithoutRestore
    /// 都需要「先 CAS 校验、再物理删子行」的同一条纪律，差异只在文件阶段
    /// （cleanup 恢复备份，finalize 丢弃备份），因此 DB 段收敛到这里。
    public enum DeliveryDeleteOutcome: String, Sendable, Equatable {
        /// 行已删除。
        case deleted
        /// 行本来就不存在（重放幂等）。
        case alreadyGone
        /// xmp_path 仍在但 id 已变（删除后重建：新输入必须保留）。
        case idChanged
        /// revision 已推进（新输入必须保留）。
        case revisionChanged
        /// 状态不再是 synced，或还有未确认的关联会话。
        case stateChanged
    }

    /// 单事务删除一条 synced 交付：delivery_items → delivery_sessions → deliveries。
    ///
    /// 守卫（全部在同一事务内读取，避免文件阶段 await 期间的状态漂移）：
    /// - id 与 revision 必须与调用方快照一致；
    /// - status 必须是 synced；
    /// - 所有关联会话都必须已确认（linkSession 会把 confirmed_at 重置为 ''，
    ///   不能替别的会话删行）。
    ///
    /// 删不掉时返回 outcome（不是错误）：replay 需要区分「幂等完成」与
    /// 「新输入保留」。显式删子行而不是依赖 CASCADE，与 cleanup 的既有顺序一致。
    @discardableResult
    public func deleteSyncedDelivery(
        xmpPath: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        let path = try normalizedPath(xmpPath)
        guard deliveryId > 0 else {
            throw DeliveryRepoError.invalidArgument("deliveryId 必须为正: \(deliveryId)")
        }
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
        return try connection.transaction {
            try deleteSyncedDeliveryInTransaction(
                path: path, deliveryId: deliveryId, revision: revision)
        }
    }

    /// 事务内变体（WP2b）：调用方已持有 connection.transaction 时使用。
    ///
    /// DeliveryDBPhase 用它把「删除 deliveries/items/links」与
    /// DeliveryIntentRepo.finishInTransaction 放进同一事务：任一步失败整体回滚，
    /// 不再出现「行已删、intent 未收尾」的崩溃窗口。
    @discardableResult
    public func deleteSyncedDeliveryInTransaction(
        xmpPath: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        let path = try normalizedPath(xmpPath)
        try Self.validateDeleteArguments(deliveryId: deliveryId, revision: revision)
        return try deleteSyncedDeliveryBody(
            path: path, deliveryId: deliveryId, revision: revision)
    }

    /// 事务内变体（已归一化 path 的内部实现；供公开包装复用）。
    @discardableResult
    private func deleteSyncedDeliveryInTransaction(
        path: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        try deleteSyncedDeliveryBody(
            path: path, deliveryId: deliveryId, revision: revision)
    }

    private static func validateDeleteArguments(deliveryId: Int64, revision: Int64) throws {
        guard deliveryId > 0 else {
            throw DeliveryRepoError.invalidArgument("deliveryId 必须为正: \(deliveryId)")
        }
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
    }

    private func deleteSyncedDeliveryBody(
        path: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        guard let current = try get(path) else { return .alreadyGone }
        guard current.id == deliveryId else { return .idChanged }
        guard current.revision == revision else { return .revisionChanged }
        guard current.typedStatus == .synced else { return .stateChanged }
        let unconfirmedLinks = try connection.prepare("""
            SELECT COUNT(*) FROM delivery_sessions
            WHERE delivery_id = ? AND confirmed_at = ''
            """).get([.int(deliveryId)])?[0].intValue ?? 0
        guard unconfirmedLinks == 0 else { return .stateChanged }
        _ = try connection.prepare("DELETE FROM delivery_items WHERE delivery_id = ?")
            .run([.int(deliveryId)])
        _ = try connection.prepare("DELETE FROM delivery_sessions WHERE delivery_id = ?")
            .run([.int(deliveryId)])
        let removed = try connection.prepare("""
            DELETE FROM deliveries
            WHERE id = ? AND revision = ? AND status = ?
            """).run([
                .int(deliveryId),
                .int(revision),
                .text(DeliveryStatus.synced.rawValue),
            ])
        guard removed == 1 else {
            // 事务内已校验仍删不掉：宁可抛错回滚子行删除，也不留半删状态。
            throw DeliveryRepoError.writeNotPersisted("delivery#\(deliveryId)")
        }
        return .deleted
    }

    // MARK: - 确认（单事务）

    /// 本会话对交付的确认。**一个 connection.transaction，闭包内无 await**（draft §5.4）。
    ///
    /// P1-3：门禁读与状态更新在同一事务内，顺序为：
    /// 1. 事务内重读会话聚合（完整性与阻断项）；不可确认则抛
    ///    `DeliveryConfirmGateError.incomplete`，整个事务回滚、不写任何 confirmed_at；
    /// 2. 可选 reload-ack 门禁（`requireReloadAck`）也在同一事务内读 sessions；
    /// 3. 本次 scope 命中的 delivery_sessions 行写 confirmed_at——**只对
    ///    `deliveries.status IN ('written','synced')` 的行**，避免门禁读之后被
    ///    mergeInput 重开为 pending/writing/failed/conflict 的交付仍落确认；
    /// 4. 仅当「该 delivery 的所有关联会话都已确认」时，written → synced；
    /// 5. 这些 delivery 下所有 written items → synced（一个侧车文件是一次原子写入，
    ///    文件内容没有模块边界；scope=.module 只收窄「确认哪些 delivery 的链接」，
    ///    不把同一文件里其它模块的已写 items 留在 written）；
    /// 6. 读回 summary（本次计数 + 仍未确认的会话）。
    ///
    /// 事务用 BEGIN IMMEDIATE 开启（与迁移器同一理由）：门禁读之前先拿写锁，
    /// 进程内靠连接锁、跨进程靠 SQLite 写锁串行化「门禁判定 → confirmed_at
    /// 更新」；不会出现 deferred 读→写升级的 BUSY_SNAPSHOT，也不会写半套确认。
    ///
    /// scope=.session 时 module 参数被忽略（确认范围是整个会话，宽于模块过滤）。
    ///
    /// 与 draft §5.4 的两处收敛（均为避免跨会话副作用）：
    /// - synced 翻转限定在本次 scope 命中的 delivery 集合内（draft 的 SQL 未限定）；
    /// - confirmed_at 只写空值行（重复 confirm 幂等，summary 计数 = 本次新确认数）。
    ///
    /// 会话级写回态由 DeliverySummaryQuery 按 deliveries 聚合派生（D-021）；
    /// 本事务的门禁读与回读复用同一投影，不再有 legacy sessions 列。
    public func confirm(
        scope: DeliveryConfirmScope,
        sessionId: String,
        module: DeliveryModule? = nil,
        requireReloadAck: Bool = false
    ) throws -> DeliveryConfirmSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        if scope == .module, module == nil {
            throw DeliveryRepoError.invalidArgument("scope=.module 必须提供 module")
        }

        let gateModule: DeliveryModule? = scope == .module ? module : nil
        let targetSQL: String
        let targetValues: [DBValue?]
        switch scope {
        case .session:
            targetSQL = "SELECT tds.delivery_id FROM delivery_sessions tds WHERE tds.session_id = ?"
            targetValues = [.text(sessionId)]
        case .module:
            targetSQL = """
                SELECT tds.delivery_id FROM delivery_sessions tds
                WHERE tds.session_id = ?
                  AND EXISTS (
                    SELECT 1 FROM delivery_items di
                    JOIN photos p ON p.id = di.photo_id
                    WHERE di.delivery_id = tds.delivery_id
                      AND di.module = ?
                      AND p.session_id = ?
                  )
                """
            targetValues = [.text(sessionId), .text(module?.rawValue ?? ""), .text(sessionId)]
        }
        let now = nowISOString()

        return try connection.transaction(.immediate) {
            // P1-3：门禁读与写入同一事务。聚合查询复用 DeliverySummaryQuery，
            // 阻断项文案/顺序与 Coordinator 的只读摘要完全一致。
            let gate = try DeliverySummaryQuery(connection: connection)
                .summary(sessionId: sessionId, module: gateModule)
            guard gate.isConfirmable else {
                throw DeliveryConfirmGateError.incomplete(blockers: gate.blockers)
            }
            if requireReloadAck {
                let acked = try connection.prepare(
                    "SELECT reload_acked_at FROM sessions WHERE id = ?"
                ).get([.text(sessionId)])?[0].textValue ?? ""
                guard !acked.isEmpty else {
                    throw DeliveryConfirmGateError.reloadNotAcknowledged(sessionId: sessionId)
                }
            }

            // confirmed_at 只写「内容仍是已写/已确认」的交付：pending/writing/
            // failed/conflict 的交付即使命中 scope 也不落确认（P1-3 的窄窗口）。
            // 保留 synced：linkSession 给已确认交付新增会话时，新链接仍可补确认，
            // 不改变任何内容基线。
            let confirmedLinks = try connection.prepare("""
                UPDATE delivery_sessions SET confirmed_at = ?
                WHERE session_id = ? AND confirmed_at = ''
                  AND delivery_id IN (
                    SELECT d.id FROM deliveries d
                    WHERE d.status IN ('written', 'synced')
                      AND d.id IN (\(targetSQL))
                  )
                """).run([.text(now), .text(sessionId)] + targetValues)

            let deliveriesSynced = try connection.prepare("""
                UPDATE deliveries SET status = 'synced', updated_at = ?
                WHERE status = 'written'
                  AND id IN (\(targetSQL))
                  AND EXISTS (
                    SELECT 1 FROM delivery_sessions ds WHERE ds.delivery_id = deliveries.id
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM delivery_sessions ds
                    WHERE ds.delivery_id = deliveries.id AND ds.confirmed_at = ''
                  )
                """).run([.text(now)] + targetValues)

            let itemsSynced = try connection.prepare("""
                UPDATE delivery_items SET status = 'synced', updated_at = ?
                WHERE status = 'written'
                  AND delivery_id IN (
                    SELECT d.id FROM deliveries d
                    WHERE d.status = 'synced' AND d.id IN (\(targetSQL))
                  )
                """).run([.text(now)] + targetValues)

            let unconfirmed = try connection.prepare("""
                SELECT DISTINCT ds.session_id
                FROM delivery_sessions ds
                WHERE ds.confirmed_at = ''
                  AND ds.delivery_id IN (\(targetSQL))
                ORDER BY ds.session_id
                """).query(targetValues)

            return DeliveryConfirmSummary(
                scope: scope,
                confirmedLinks: confirmedLinks,
                deliveriesSynced: deliveriesSynced,
                itemsSynced: itemsSynced,
                unconfirmedSessionIds: unconfirmed.compactMap { $0[0].textValue }
            )
        }
    }
}

/// 确认范围：整个会话，或「该会话下含指定模块 item 的交付」。
public enum DeliveryConfirmScope: String, Sendable, CaseIterable, Equatable {
    case session
    case module
}

/// confirm 的读回摘要（供 UI / 审计；全部在 confirm 的同一事务内读取）。
public struct DeliveryConfirmSummary: Sendable, Equatable {
    public let scope: DeliveryConfirmScope
    /// 本次新确认的 delivery_sessions 行数（已确认行不重复计数）。
    public let confirmedLinks: Int
    /// 本次由 written 翻到 synced 的 delivery 行数。
    public let deliveriesSynced: Int
    /// 本次由 written 翻到 synced 的 item 行数。
    public let itemsSynced: Int
    /// 本次 scope 命中的 delivery 上仍未确认的会话（跨会话门禁的 UI 输入）。
    public let unconfirmedSessionIds: [String]

    public init(
        scope: DeliveryConfirmScope,
        confirmedLinks: Int,
        deliveriesSynced: Int,
        itemsSynced: Int,
        unconfirmedSessionIds: [String]
    ) {
        self.scope = scope
        self.confirmedLinks = confirmedLinks
        self.deliveriesSynced = deliveriesSynced
        self.itemsSynced = itemsSynced
        self.unconfirmedSessionIds = unconfirmedSessionIds
    }
}
