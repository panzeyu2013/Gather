// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryIntentRepo.swift
// Cut 2 / S3：delivery_intents 持久化层（draft §5.2 / §5.5，D-023）。
//
// 边界（本批刻意最小）：
// 1. **只做 DB 记账，不做任何文件 IO**：cleanup 的文件恢复/删除由调用方（后续
//    DeliveryCoordinator）在 prepare 与 advance(.fileDone) 之间执行；本仓储不碰
//    FileManager，也不解释 payload_json 的业务字段。
// 2. **相位唯一入口**：prepared → fileDone → applied 的合法性只由
//    DeliveryIntentPhase.canTransition 定义；advance 非法迁移抛
//    DeliveryIntentRepoError.illegalTransition，绝不静默跳相位。
// 3. **终态清理**：applied 是终态标记；finish(error: nil) 直接删除 intent，
//    finish(error:) 标记 applied + error_message（调用方显式放弃重放），
//    replayAll() 在启动回放时删除全部 applied 行。
// 4. **显式列 + 参数绑定**：所有 SELECT 列出列名，INSERT/UPDATE 全部用 ? 绑定，
//    行映射按列名取值，不依赖 DDL 物理列序（与 DeliveryRepo 同一纪律）。
// 5. **无 FK 依赖**：delivery_intents.xmp_path 刻意无 FK（draft §5.5 硬规则 3），
//    父 deliveries 行被删除后 intent 仍存续，回放才有上下文。

import Foundation
import GatherProtocol

/// delivery_intents.kind 的合法值（与 SchemaCurrent 的 CHECK 双向一致）。
public enum DeliveryIntentKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// 清理回滚：把备份内容恢复回 XMP，然后删除交付行。
    case cleanup
    /// 写盘意图（预留：S3 只持久化，不接线写路径）。
    case write
}

/// delivery_intents.phase 的合法值（与 SchemaCurrent 的 CHECK 双向一致）。
///
/// 回放语义（draft §5.5）：
/// - prepared：文件操作可能完全没做，回放时**重做文件 + 重做 DB**；
/// - fileDone：文件已是目标状态，回放时**只补 DB 段**，绝不重放文件；
/// - applied：终态，回放时删除 intent 行。
public enum DeliveryIntentPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case prepared
    case fileDone
    case applied

    /// 唯一转移表：只允许前进一步。自迁移/跳相位/回退一律拒绝
    /// （回放代码按相位分支处理，重复 advance 属于调用方 bug，应显式暴露）。
    public func canTransition(to next: DeliveryIntentPhase) -> Bool {
        switch (self, next) {
        case (.prepared, .fileDone), (.fileDone, .applied):
            return true
        default:
            return false
        }
    }

    /// 终态（不可再 advance）。
    public var isTerminal: Bool { self == .applied }
}

/// intent 仓储错误。非法相位迁移是本文件唯一允许抛出的「状态机拒绝」。
///
/// 与 DeliveryRepoError 分开：intent 的主键是自增 id，错误上下文需要 id + xmpPath；
/// 两者都不映射 GatherErrorCode（D-023 第 5 条，接线时在 API 边界转换）。
public enum DeliveryIntentRepoError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 迁移表拒绝。
    case illegalTransition(id: Int64, xmpPath: String, from: String, to: String)
    /// 行不存在（advance/finish 必须显式失败，不能静默 no-op）。
    case rowNotFound(id: Int64)
    /// SELECT 缺少必需列（显式列清单与行映射器漂移）。
    case missingColumn(String)
    /// 写入后无法读回/拿不到自增 id（不得谎报成功）。
    case writeNotPersisted(Int64)
    /// 调用参数非法（空路径 / 非正 id）。
    case invalidArgument(String)

    public var code: String {
        switch self {
        case .illegalTransition: return "DELIVERY_INTENT_ILLEGAL_TRANSITION"
        case .rowNotFound: return "DELIVERY_INTENT_NOT_FOUND"
        case .missingColumn: return "DELIVERY_INTENT_MISSING_COLUMN"
        case .writeNotPersisted: return "DELIVERY_INTENT_NOT_PERSISTED"
        case .invalidArgument: return "DELIVERY_INTENT_INVALID_ARGUMENT"
        }
    }

    public var description: String {
        switch self {
        case .illegalTransition(let id, let path, let from, let to):
            return "\(code): #\(id) \(path) \(from) -> \(to)"
        case .rowNotFound(let id):
            return "\(code): #\(id)"
        case .missingColumn(let name):
            return "\(code): \(name)"
        case .writeNotPersisted(let id):
            return "\(code): #\(id)"
        case .invalidArgument(let message):
            return "\(code): \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// delivery_intents 表行（8 列，与 SchemaCurrent §5.2 一致）。
public struct DeliveryIntentRow: Sendable, Equatable {
    public let id: Int64
    public let kind: String
    public let xmpPath: String
    public let phase: String
    public let payloadJSON: String
    public let errorMessage: String
    public let createdAt: String
    public let updatedAt: String

    /// 显式列清单（唯一来源；SQL 与映射器都由它派生）。
    public static let columnNames: [String] = [
        "id", "kind", "xmp_path", "phase", "payload_json",
        "error_message", "created_at", "updated_at",
    ]

    static var selectList: String { columnNames.joined(separator: ", ") }

    public init(columns: [String], row: DBRow) throws {
        guard columns.count == row.count else {
            throw DeliveryIntentRepoError.invalidArgument(
                "列名与行宽不一致: \(columns.count) vs \(row.count)")
        }
        var map: [String: DBValue] = [:]
        for (index, name) in columns.enumerated() {
            map[name] = row[index]
        }
        for name in Self.columnNames where map[name] == nil {
            throw DeliveryIntentRepoError.missingColumn(name)
        }
        func text(_ name: String) -> String { map[name]?.textValue ?? "" }
        func int(_ name: String) -> Int64 { map[name]?.intValue ?? 0 }

        id = int("id")
        kind = text("kind")
        xmpPath = text("xmp_path")
        phase = text("phase")
        payloadJSON = text("payload_json")
        errorMessage = text("error_message")
        createdAt = text("created_at")
        updatedAt = text("updated_at")
    }

    public var typedKind: DeliveryIntentKind? { DeliveryIntentKind(rawValue: kind) }
    public var typedPhase: DeliveryIntentPhase? { DeliveryIntentPhase(rawValue: phase) }

    /// payload_json 的解析结果；损坏/空串回退空对象（与 DeliveryRow.baseValues 同口径）。
    public var payload: JSONValue {
        (try? JSONValue.parse(payloadJSON)) ?? .object([:])
    }
}

/// pending()/replayAll() 的回放待办：按相位分开，每个列表内按 id 升序。
///
/// 为什么要分开：两相位的回放动作不同（prepared 重做文件+DB，fileDone 只补 DB）。
/// 调用方必须逐相位处理，不能把两个列表混在一起迭代。
public struct DeliveryIntentBacklog: Sendable, Equatable {
    /// 文件可能没做：先重做文件，再补 DB 段。
    public let prepared: [DeliveryIntentRow]
    /// 文件已完成：只补 DB 段，绝不重放文件。
    public let fileDone: [DeliveryIntentRow]
    /// 已应用（终态）：cleanup 的显式放弃记录，或 finalize 已删行但备份尚未清理。
    /// pending() 不返回；只有 replayAll() 返回，供启动时补删备份后清行。
    public let applied: [DeliveryIntentRow]

    public init(
        prepared: [DeliveryIntentRow],
        fileDone: [DeliveryIntentRow],
        applied: [DeliveryIntentRow] = []
    ) {
        self.prepared = prepared
        self.fileDone = fileDone
        self.applied = applied
    }

    public var isEmpty: Bool { prepared.isEmpty && fileDone.isEmpty && applied.isEmpty }

    public var count: Int { prepared.count + fileDone.count + applied.count }

    /// 展平列表（prepared 在前、fileDone 次之、applied 最后；相位内 id 升序）。
    /// 仅供审计/日志；实际回放必须按相位分支，不能用本列表驱动文件操作。
    public var all: [DeliveryIntentRow] { prepared + fileDone + applied }
}

/// delivery_intents 仓储（S3 只做持久化 + 回放待办读取，不做文件 IO）。
public final class DeliveryIntentRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 路径口径

    /// 与 DeliveryRepo 相同：只做路径标准化，不猜测 photo→sidecar。
    private func normalizedPath(_ xmpPath: String) throws -> String {
        let path = TSPath.normalize(xmpPath)
        // 只对「空白」做拒绝判定，不裁剪真实路径（路径组件允许含空格）。
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeliveryIntentRepoError.invalidArgument("xmpPath 不能为空")
        }
        return path
    }

    // MARK: - 写入

    /// 阶段 A：在文件操作前持久化一条 prepared 意图，返回自增 id。
    ///
    /// payload 原样写入 payload_json（例如 cleanup 的 backup_path/delivery_id/revision）；
    /// 本方法不校验 payload 结构（仓储不解释业务字段）。
    /// 每条 intent 独立成行，没有 (xmp_path, kind) 唯一约束——同一 sidecar 可以有多条
    /// 未完成的意图，调用方负责在 finish 后不再 prepare。
    @discardableResult
    public func prepare(
        kind: DeliveryIntentKind,
        xmpPath: String,
        payload: JSONValue = .object([:])
    ) throws -> Int64 {
        let path = try normalizedPath(xmpPath)
        let payloadJSON = try JSONValue.stringify(payload)
        let now = nowISOString()
        let id = try connection.transaction {
            _ = try connection.prepare("""
                INSERT INTO delivery_intents (
                  kind, xmp_path, phase, payload_json, error_message, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """).run([
                    .text(kind.rawValue), .text(path),
                    .text(DeliveryIntentPhase.prepared.rawValue),
                    .text(payloadJSON), .text(""), .text(now), .text(now),
                ])
            return connection.lastInsertRowid
        }
        guard id > 0 else { throw DeliveryIntentRepoError.writeNotPersisted(id) }
        return id
    }

    /// 相位推进：prepared → fileDone → applied，非法迁移抛错。
    ///
    /// 返回推进后的行（读回失败即抛 writeNotPersisted，不谎报成功）。
    /// 注意：本方法只改 intent 行，**不执行任何文件操作**，也不碰 deliveries。
    @discardableResult
    public func advance(id: Int64, to phase: DeliveryIntentPhase) throws -> DeliveryIntentRow {
        guard id > 0 else {
            throw DeliveryIntentRepoError.invalidArgument("id 必须为正: \(id)")
        }
        return try connection.transaction {
            guard let current = try intent(id) else {
                throw DeliveryIntentRepoError.rowNotFound(id: id)
            }
            guard let currentPhase = current.typedPhase else {
                throw DeliveryIntentRepoError.invalidArgument(
                    "未知 phase: \(current.phase) (#\(id))")
            }
            guard currentPhase.canTransition(to: phase) else {
                throw DeliveryIntentRepoError.illegalTransition(
                    id: id, xmpPath: current.xmpPath,
                    from: currentPhase.rawValue, to: phase.rawValue)
            }
            let now = nowISOString()
            let changed = try connection.prepare("""
                UPDATE delivery_intents SET phase = ?, updated_at = ?
                WHERE id = ? AND phase = ?
                """).run([
                    .text(phase.rawValue), .text(now), .int(id),
                    .text(currentPhase.rawValue),
                ])
            guard changed == 1 else {
                // 同一 connection 的事务锁内不应发生；保留显式失败以防未来多连接。
                throw DeliveryIntentRepoError.writeNotPersisted(id)
            }
            guard let updated = try intent(id) else {
                throw DeliveryIntentRepoError.writeNotPersisted(id)
            }
            return updated
        }
    }

    /// 阶段 D 的终态收尾：
    /// - error 为空/nil：删除 intent（成功闭环，日志不再需要）；
    /// - error 非空：标记 applied + error_message（调用方显式放弃重放，保留终态记录，
    ///   等待 replayAll 清理）。
    ///
    /// **不要**在「文件已恢复、但 DB 段失败且仍想重试」时调用 error 分支——那会把 intent
    /// 标成终态，回放不再补 DB。此时应保留 fileDone 相位，交给下次 replayAll 重试。
    public func finish(id: Int64, error: String? = nil) throws {
        guard id > 0 else {
            throw DeliveryIntentRepoError.invalidArgument("id 必须为正: \(id)")
        }
        try connection.transaction {
            try finishInTransaction(id: id, error: error)
        }
    }

    /// 事务内收尾（WP2b）：调用方必须已持有 connection.transaction。
    ///
    /// DeliveryDBPhase 用它把「DB 删除 deliveries」与 intent 收尾放进同一事务：
    /// 删除成功但收尾失败时，外层事务把删除一并回滚；不会留下「文件已恢复、
    /// DB 已删、intent 还在」的三种事实并存窗口。
    public func finishInTransaction(id: Int64, error: String? = nil) throws {
        guard id > 0 else {
            throw DeliveryIntentRepoError.invalidArgument("id 必须为正: \(id)")
        }
        guard try intent(id) != nil else {
            throw DeliveryIntentRepoError.rowNotFound(id: id)
        }
        let now = nowISOString()
        if let error, !error.isEmpty {
            _ = try connection.prepare("""
                UPDATE delivery_intents SET phase = ?, error_message = ?, updated_at = ?
                WHERE id = ?
                """).run([
                    .text(DeliveryIntentPhase.applied.rawValue),
                    .text(error), .text(now), .int(id),
                ])
        } else {
            _ = try connection.prepare("DELETE FROM delivery_intents WHERE id = ?")
                .run([.int(id)])
        }
    }

    // MARK: - 读取 / 回放待办

    /// 按 id 读一行（显式列）。id 非正时返回 nil（不可能存在）。
    public func get(_ id: Int64) throws -> DeliveryIntentRow? {
        guard id > 0 else { return nil }
        return try intent(id)
    }

    /// 当前所有非终态 intent，按相位分开（每个列表内 id 升序）。
    /// **只读**：不做文件操作，不改任何行；applied 行不返回。
    public func pending() throws -> DeliveryIntentBacklog {
        try backlog()
    }

    /// 启动回放的入口（draft §5.5）：先删除终态 applied 行，再返回需要处理的
    /// prepared/fileDone 待办。本方法**不做文件操作**，文件段由调用方按相位执行。
    ///
    /// 因此调用方必须：
    /// 1. 对 prepared：重做文件 + 重做 DB；
    /// 2. 对 fileDone：只补 DB，绝不重做文件；
    /// 3. 处理完调用 finish/advance 闭环。
    /// 重复调用幂等：第二次调用只会看到仍未闭环的 intent。
    @discardableResult
    public func replayAll() throws -> DeliveryIntentBacklog {
        try connection.transaction {
            let pending = try backlog()
            // 复审 A3：applied 不再无脑删除——finalize 的 applied 行可能还指向
            // 一份尚未删除的备份；调用方必须先补删备份，再 finish(nil) 清行。
            let applied = try appliedRows()
            return DeliveryIntentBacklog(
                prepared: pending.prepared,
                fileDone: pending.fileDone,
                applied: applied
            )
        }
    }

    /// 终态 applied 行（id 升序）；不做文件操作。
    private func appliedRows() throws -> [DeliveryIntentRow] {
        let rows = try connection.prepare("""
            SELECT \(DeliveryIntentRow.selectList)
            FROM delivery_intents
            WHERE phase = ?
            ORDER BY id ASC
            """).query([.text(DeliveryIntentPhase.applied.rawValue)])
        return try rows.map {
            try DeliveryIntentRow(columns: DeliveryIntentRow.columnNames, row: $0)
        }
    }

    // MARK: - 内部

    private func intent(_ id: Int64) throws -> DeliveryIntentRow? {
        guard let row = try connection.prepare("""
            SELECT \(DeliveryIntentRow.selectList)
            FROM delivery_intents
            WHERE id = ?
            """).get([.int(id)]) else { return nil }
        return try DeliveryIntentRow(columns: DeliveryIntentRow.columnNames, row: row)
    }

    /// 非终态待办查询（显式列 + 参数绑定；两相位一次查询后分流，保持 id 顺序）。
    private func backlog() throws -> DeliveryIntentBacklog {
        let rows = try connection.prepare("""
            SELECT \(DeliveryIntentRow.selectList)
            FROM delivery_intents
            WHERE phase IN (?, ?)
            ORDER BY id ASC
            """).query([
                .text(DeliveryIntentPhase.prepared.rawValue),
                .text(DeliveryIntentPhase.fileDone.rawValue),
            ])
        var prepared: [DeliveryIntentRow] = []
        var fileDone: [DeliveryIntentRow] = []
        for row in rows {
            let intent = try DeliveryIntentRow(columns: DeliveryIntentRow.columnNames, row: row)
            switch intent.typedPhase {
            case .prepared:
                prepared.append(intent)
            case .fileDone:
                fileDone.append(intent)
            case .applied, .none:
                // WHERE 已排除 applied；未知相位说明 CHECK/枚举漂移，显式失败。
                throw DeliveryIntentRepoError.invalidArgument(
                    "回放查询返回未知 phase: \(intent.phase) (#\(intent.id))")
            }
        }
        return DeliveryIntentBacklog(prepared: prepared, fileDone: fileDone)
    }
}