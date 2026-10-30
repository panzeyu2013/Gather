// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataDeliveryService.swift
// P1 下一波 §3.1：metadata/template 写回的**生命周期服务**（读状态 / 自动确认 /
// module 作用域结束 / 备份统计）。
//
// 边界：
// 1. 状态只读不写：state() 是 deliveries/delivery_items 的只读投影，不写 sessions
//    （D-021 不变）；
// 2. 确认/结束都经 DeliveryCoordinator（唯一编排入口），这里只做"两个模块分别
//    处理 + 错误码收敛 + 派生状态"，不复制状态机、不碰文件；
// 3. 自动确认（§3.1.2 的默认策略）：写盘成功后立刻确认；两个例外——
//    - metadata_sync_auto_confirm=0 → 全手动；
//    - reload-ack 门禁生效且本会话未 ack（C1 还显示旧值）→ 保持 written，
//      等 reload 成功后的下一次同步动作再确认（状态条显示"待 C1 重载"）；
// 4. 结束（finalize）**只做 drop**：保留 XMP、只删本模块 synced item；
//    共享文件上仍有其它模块 item 时保留行与备份并记 retained，绝不 restore。
//
// 为什么不在 GatherDelivery：元数据生命周期要读设置（保留期/自动确认）并面向 UI
// 产出 DTO；把它塞进交付引擎会让引擎反向依赖应用层。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

// MARK: - 结果类型

/// 写盘成功后的自动确认结论。
public enum MetadataAutoConfirmOutcome: Equatable, Sendable {
    /// 已确认（links/deliveries/items = 本次实际翻转的行数；第二个模块调用幂等）。
    case confirmed(links: Int, deliveries: Int, items: Int)
    /// C1 待重载：保持 written，等 reload 后再确认。
    case deferredToReloadAck
    /// metadata_sync_auto_confirm=0：完全手动。
    case disabled
    /// 没有需要确认的行。
    case nothingToDo
    /// 确认没成功（写盘已成功；错误只影响"可结束"的推进，不改变写盘结果）。
    case failed(String)
}

/// 结束同步的结果（协议只回状态，控制器/维护页还需要计数做 notice 与日志）。
public struct MetadataFinalizeOutcome: Sendable, Equatable {
    public var deleted: Int
    public var retained: Int
    public var skipped: Int
    public var errors: [String]
    public var state: MetadataDeliveryState

    public init(
        deleted: Int,
        retained: Int,
        skipped: Int,
        errors: [String],
        state: MetadataDeliveryState
    ) {
        self.deleted = deleted
        self.retained = retained
        self.skipped = skipped
        self.errors = errors
        self.state = state
    }
}

/// 元数据备份统计（设置页"维护"与诊断用）。
public struct MetadataBackupStats: Sendable, Equatable {
    public var count: Int
    public var bytes: Int64
    /// 最老备份的天数（没有备份时 nil）。
    public var oldestDays: Int?

    public init(count: Int, bytes: Int64, oldestDays: Int?) {
        self.count = count
        self.bytes = bytes
        self.oldestDays = oldestDays
    }
}

/// 生命周期服务的显式失败（不映射 GatherErrorCode；API 边界再转，D-030 的既有分工）。
public enum MetadataDeliveryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 入参非法（空/超长 sessionId 等）。
    case invalidParameter(String)
    /// confirm 门禁：仍有 pending/writing/failed/conflict → XMP_CONFIRM_INCOMPLETE。
    case confirmIncomplete([String])
    /// C1 未 reload → XMP_CONFIRM_REQUIRES_SYNC。
    case reloadNotAcknowledged

    public var code: String {
        switch self {
        case .invalidParameter: return "INVALID_PARAM"
        case .confirmIncomplete: return "XMP_CONFIRM_INCOMPLETE"
        case .reloadNotAcknowledged: return "XMP_CONFIRM_REQUIRES_SYNC"
        }
    }

    public var description: String {
        switch self {
        case .invalidParameter(let message):
            return "\(code): \(message)"
        case .confirmIncomplete(let blockers):
            return "\(code): " + blockers.joined(separator: ",")
        case .reloadNotAcknowledged:
            return code
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - 服务

public struct MetadataDeliveryService: Sendable {
    /// 设置键（与 SettingsService.getDefaults() 同源；本服务只读）。
    public static let autoConfirmKey = "metadata_sync_auto_confirm"
    public static let autoFinalizeKey = "metadata_sync_auto_finalize"
    public static let retentionDaysKey = "metadata_backup_retention_days"

    /// 元数据写回涉及的交付模块（写盘落在 .metadata；.template 是预留的独立队列，
    /// 两个模块分别确认/结束，第二次调用是幂等）。
    public static let modules: [DeliveryModule] = [.metadata, .template]

    private let connection: DBConnection
    private let lifecycle: MetadataLifecycleRepo
    private let coordinator: DeliveryCoordinator
    private let getSetting: @Sendable (String, String) -> String
    private let now: @Sendable () -> Date

    public init(
        connection: DBConnection,
        coordinator: DeliveryCoordinator,
        getSetting: @escaping @Sendable (String, String) -> String = { _, _ in "" },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connection = connection
        self.lifecycle = MetadataLifecycleRepo(connection: connection)
        self.coordinator = coordinator
        self.getSetting = getSetting
        self.now = now
    }

    // MARK: - 读状态（§3.1.2）

    /// 本会话 metadata/template 两个模块的交付状态（含备份体积与逐文件行）。
    ///
    /// 计数按**交付**去重（一个 sidecar 一行）：metadata 与 template 的 item 落在
    /// 同一交付上时只算一次，绝不把 delivery 与 item 相加。
    public func state(sessionId: String) throws -> MetadataDeliveryState {
        let id = try requireSession(sessionId)
        var state = MetadataDeliveryState()
        state.requiresReloadAck = coordinator.reloadAckGateEnabled
        for row in try deliveryRows(sessionId: id) {
            switch row.status {
            case .pending: state.pending += 1
            case .writing, .clean:
                // writing 不是稳定展示态（租约在手，下一次刷新就会变）；
                // clean 是 V1 不产生的历史值。两者都不计入"待确认/可结束"。
                state.pending += 1
            case .written: state.written += 1
            case .synced: state.synced += 1
            case .failed: state.failed += 1
            case .conflict: state.conflict += 1
            case .cleaned:
                // 审计终态不计入"可结束"；物理删除后行本身就不在了。
                break
            }
            state.rows.append(MetadataDeliveryRow(
                xmpPath: row.xmpPath,
                status: row.status.rawValue,
                modules: row.modules,
                backupBytes: Int(Self.fileSize(row.backupPath)),
                updatedAt: row.updatedAt
            ))
        }
        let backups = try backupTotals(sessionId: id)
        state.backupCount = backups.count
        state.backupBytes = backups.bytes
        return state
    }

    /// 备份统计（设置页维护 / 诊断）。sessionId 为 nil 时统计全库。
    public func backupStats(sessionId: String? = nil) throws -> MetadataBackupStats {
        let backups = try backupTotals(sessionId: sessionId)
        let oldestDays: Int?
        if let oldest = backups.oldest {
            let interval = now().timeIntervalSince(oldest)
            oldestDays = interval <= 0 ? 0 : Int(interval / 86_400)
        } else {
            oldestDays = nil
        }
        return MetadataBackupStats(
            count: backups.count, bytes: backups.bytes, oldestDays: oldestDays)
    }

    // MARK: - 确认

    /// 确认同步（.metadata + .template 各一次；第二次幂等）。
    public func confirmSync(sessionId: String) throws -> MetadataDeliveryState {
        let id = try requireSession(sessionId)
        do {
            for module in Self.modules {
                _ = try coordinator.confirm(sessionId: id, module: module)
            }
        } catch let error as DeliveryCoordinatorError {
            throw Self.mapGate(error)
        }
        return try state(sessionId: id)
    }

    /// 写盘成功后的自动确认（§3.1.2）。
    ///
    /// 不抛：写盘已经成功，确认失败不能反过来把写盘报成失败；结果码让调用方
    /// 决定是否提示。C1 待重载与"关闭自动确认"都保持 written。
    public func autoConfirmAfterWrite(
        sessionId: String,
        modules: [DeliveryModule] = MetadataDeliveryService.modules
    ) -> MetadataAutoConfirmOutcome {
        let id: String
        do {
            id = try requireSession(sessionId)
        } catch {
            return .failed(MetadataDeliveryError.invalidParameter(
                "sessionId 不能为空").description)
        }
        if getSetting(Self.autoConfirmKey, "1") == "0" {
            return .disabled
        }
        let awaitingAck: Bool
        do {
            awaitingAck = try coordinator.isAwaitingReloadAck(sessionId: id)
        } catch {
            return .failed(String(describing: error))
        }
        if awaitingAck {
            // C1 还显示旧值：保持 written，reload 成功后的下一次同步动作再确认。
            return .deferredToReloadAck
        }
        var links = 0
        var deliveries = 0
        var items = 0
        for module in modules {
            do {
                let summary = try coordinator.confirm(sessionId: id, module: module)
                links += summary.confirmedLinks
                deliveries += summary.deliveriesSynced
                items += summary.itemsSynced
            } catch let error as DeliveryCoordinatorError {
                // 未确认的项（failed/conflict）或并发状态变化：写盘结果不变，
                // 只是这一轮没能推进到 synced。逐条进日志，返回值让调用方可见。
                GatherLogger.log(
                    "metadata auto-confirm skipped module=\(module.rawValue) "
                        + "session=\(Self.sessionToken(id)) reason=\(error.code)",
                    level: .warn)
                return .failed(error.code)
            } catch {
                GatherLogger.log(
                    "metadata auto-confirm failed module=\(module.rawValue) "
                        + "session=\(Self.sessionToken(id)) reason=\(String(describing: error))",
                    level: .warn)
                return .failed(String(describing: error))
            }
        }
        if links + deliveries + items == 0 {
            return .nothingToDo
        }
        return .confirmed(links: links, deliveries: deliveries, items: items)
    }

    // MARK: - 结束（module 作用域 drop）

    /// 结束同步：两个模块分别走 DeliveryCoordinator.finalize（module 作用域）。
    ///
    /// 门禁：
    /// - C1 门禁生效且本会话未 ack → XMP_CONFIRM_REQUIRES_SYNC（备份是唯一还原点）；
    /// - 本模块仍有未确认 item → 计入 skipped，notice 里带 XMP_CONFIRM_INCOMPLETE
    ///   （单个文件的未确认不阻塞其它文件结束；"先确认再结束"由 UI 提示）。
    public func finalizeSync(sessionId: String) async throws -> MetadataFinalizeOutcome {
        let id = try requireSession(sessionId)
        let awaitingAck: Bool
        do {
            awaitingAck = try coordinator.isAwaitingReloadAck(sessionId: id)
        } catch {
            throw MetadataDeliveryError.invalidParameter(String(describing: error))
        }
        if awaitingAck {
            throw MetadataDeliveryError.reloadNotAcknowledged
        }
        var deleted = 0
        var retained = 0
        var skipped = 0
        var errors: [String] = []
        for module in Self.modules {
            do {
                let summary = try await coordinator.finalize(sessionId: id, module: module)
                deleted += summary.deletedCount
                retained += summary.retainedCount
                skipped += summary.skippedCount
                errors.append(contentsOf: summary.errors)
            } catch let error as DeliveryCoordinatorError {
                switch error {
                case .reloadNotAcknowledged:
                    throw MetadataDeliveryError.reloadNotAcknowledged
                case .confirmIncomplete(let blockers):
                    throw MetadataDeliveryError.confirmIncomplete(blockers)
                case .invalidArgument(let message):
                    throw MetadataDeliveryError.invalidParameter(message)
                default:
                    errors.append(error.description)
                }
            }
        }
        var state = try state(sessionId: id)
        // "先确认再结束"：仍有已写盘未确认的行时，finalize 按设计不动它们
        // （只处理 synced），这里必须显式告诉调用方，否则"点了结束却还有 N 个文件"
        // 看起来像失败。错误码沿用 confirm 门禁码（不新增全局码）。
        if state.written > 0 {
            errors.append(
                "XMP_CONFIRM_INCOMPLETE: written=\(state.written) 先确认再结束")
        }
        // 失败可见（§3.1.5）：逐条进 state.notices（UI 直接展示）+ outcome.errors
        // （完整路径保留给用户定位；日志仍只输出 token）。
        state.notices = errors
        return MetadataFinalizeOutcome(
            deleted: deleted,
            retained: retained,
            skipped: skipped,
            errors: errors,
            state: state
        )
    }

    // MARK: - 内部：行投影

    private struct DeliveryProjection {
        let xmpPath: String
        let status: MetadataSyncStatus
        let updatedAt: String
        let backupPath: String
        var modules: [String]
    }

    /// 本会话里带 metadata/template item 的交付（按 xmp_path 去重）。
    ///
    /// 显式列 + 参数绑定；item 的 failed/pending 把交付展示态升级
    /// （与 DeliverySummaryQuery.metadataSummary 同一投影口径）。
    private func deliveryRows(sessionId: String) throws -> [DeliveryProjection] {
        var ordered: [String] = []
        var byPath: [String: DeliveryProjection] = [:]
        for row in try lifecycle.projections(sessionId: sessionId) {
            let xmpPath = row.xmpPath
            guard !xmpPath.isEmpty else { continue }
            guard let deliveryStatus = DeliveryStatus(rawValue: row.status) else {
                throw MetadataDeliveryError.invalidParameter("未知 delivery.status: \(row.status)")
            }
            let status = Self.displayStatus(
                deliveryStatus, failedItems: row.failedItems, pendingItems: row.pendingItems)
            if var existing = byPath[xmpPath] {
                if !existing.modules.contains(row.module) {
                    existing.modules.append(row.module)
                }
                existing.modules.sort()
                byPath[xmpPath] = existing
                continue
            }
            ordered.append(xmpPath)
            byPath[xmpPath] = DeliveryProjection(
                xmpPath: xmpPath,
                status: status,
                updatedAt: row.updatedAt,
                backupPath: row.backupPath,
                modules: [row.module]
            )
        }
        return ordered.compactMap { byPath[$0] }
    }

    /// 交付状态 → 旧 MetadataSyncStatus 投影（item 的未完成态升级展示态）。
    private static func displayStatus(
        _ status: DeliveryStatus,
        failedItems: Int,
        pendingItems: Int
    ) -> MetadataSyncStatus {
        switch status {
        case .conflict: return .conflict
        case .failed: return .failed
        case .writing: return .writing
        case .pending: return .pending
        case .written:
            return failedItems > 0 ? .failed : (pendingItems > 0 ? .pending : .written)
        case .synced:
            return failedItems > 0 ? .failed : (pendingItems > 0 ? .pending : .synced)
        case .cleaned: return .cleaned
        }
    }

    // MARK: - 内部：备份体积

    /// 单个备份文件的字节数（不存在/读不到 → 0）。
    private static func fileSize(_ path: String) -> Int64 {
        guard !path.isEmpty else { return 0 }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            return 0
        }
    }

    private struct BackupTotals {
        var count = 0
        var bytes: Int64 = 0
        var oldest: Date?

        mutating func add(path: String) {
            count += 1
            let attributes: [FileAttributeKey: Any]?
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: path)
            } catch {
                // 备份已消失（GC/手工清理）不是错误：仍计数，字节按 0 计。
                attributes = nil
            }
            if let size = attributes?[.size] as? NSNumber {
                bytes += size.int64Value
            }
            if let modified = attributes?[.modificationDate] as? Date {
                if let current = oldest {
                    if modified < current { oldest = modified }
                } else {
                    oldest = modified
                }
            }
        }
    }

    private func backupTotals(sessionId: String?) throws -> BackupTotals {
        var totals = BackupTotals()
        for path in try lifecycle.backupPaths(sessionId: sessionId) {
            totals.add(path: path)
        }
        return totals
    }

    // MARK: - 内部：校验与映射

    private func requireSession(_ sessionId: String) throws -> String {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            throw MetadataDeliveryError.invalidParameter("sessionId 不能为空或超长")
        }
        return trimmed
    }

    private static func mapGate(_ error: DeliveryCoordinatorError) -> MetadataDeliveryError {
        switch error {
        case .confirmIncomplete(let blockers):
            return .confirmIncomplete(blockers)
        case .reloadNotAcknowledged:
            return .reloadNotAcknowledged
        case .invalidArgument(let message):
            return .invalidParameter(message)
        default:
            return .invalidParameter(String(describing: error))
        }
    }

    // MARK: - 展示 token（路径日志/DTO 脱敏）

    /// 展示用的路径 token（basename + FNV-1a 短哈希）。
    ///
    /// 与 DeliveryTrace.pathToken 同一算法；这里必须在本层可用（交付层那个是
    /// internal 的），因此复制十行而不是把交付层内部实现公开。
    public static func pathToken(_ path: String) -> String {
        let normalized = TSPath.normalize(path)
        let basename = (normalized as NSString).lastPathComponent
        let name = basename.isEmpty ? "xmp" : basename
        return "\(name)#\(shortHash(normalized))"
    }

    /// 日志里的会话标识（完整 sessionId 不进日志）。
    public static func sessionToken(_ sessionId: String) -> String {
        guard !sessionId.isEmpty else { return "session:empty" }
        return "session:\(shortHash(sessionId))"
    }

    private static func shortHash(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}
