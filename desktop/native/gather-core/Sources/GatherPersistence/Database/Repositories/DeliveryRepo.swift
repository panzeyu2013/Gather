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
    let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 路径口径

    /// xmp 路径唯一归一化：只做路径标准化（折叠 ./..、重复斜杠），
    /// **不做** photo→sidecar 猜测（旧 outbox 的隐式转换是双写期的歧义来源）。
    func normalizedPath(_ xmpPath: String) throws -> String {
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
}
