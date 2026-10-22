// desktop/native/gather-core/Sources/GatherDelivery/Types/DeliveryTypes.swift
// WP2b：交付切片的公共值类型（自 DeliveryCoordinator.swift 纯移动）。
//
// 这里只有「端口 / 错误 / 结果 / 镜像输入」四类数据：不含编排，也不写状态。
// 移动原则：类型名、字段、初始化器、错误码与描述逐字保留，调用点不感知拆分。

import Foundation
import GatherPersistence
import GatherProtocol

// MARK: - 文件端口

/// cleanup 只需要 XMPProvider 的三个能力：存在性、restore、removeFile。
/// 用窄端口而不是整个 XMPProvider，避免 coordinator 依赖读写/备份等无关方法。
public protocol DeliveryFilePort: Sendable {
    func fileExists(_ path: String) -> Bool
    func restore(photoPath: String, backupPath: String) async throws
    func removeFile(_ path: String) async throws
}

/// XMPProvider → DeliveryFilePort 的适配器（宿主接线用）。
public struct XMPDeliveryFilePort: DeliveryFilePort {
    private let provider: any XMPProvider

    public init(_ provider: any XMPProvider) {
        self.provider = provider
    }

    public func fileExists(_ path: String) -> Bool {
        provider.fileExists(path)
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        try await provider.restore(photoPath: photoPath, backupPath: backupPath)
    }

    public func removeFile(_ path: String) async throws {
        try await provider.removeFile(path)
    }
}

/// 内容指纹（cleanup 的外部修改检测）。默认走 MetadataFingerprint；测试注入假值。
public typealias DeliveryFingerprintProvider =
    @Sendable (_ xmpPath: String) async throws -> String

/// photoPath 解析（可接 PhotoAssetResolver）。默认直接用 deliveries.photo_path。
/// sessionId 供宿主按当前会话的资产解析规则返回真实照片路径。
public typealias DeliveryPhotoPathResolver =
    @Sendable (_ sessionId: String, _ delivery: DeliveryRow) throws -> String

// MARK: - 错误 / 结果

/// coordinator 的显式失败（不映射 GatherErrorCode；D-023 第 5 条，API 边界再转）。
public enum DeliveryCoordinatorError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// confirm 门禁：存在 pending/writing/failed/conflict 的交付或 item。
    case confirmIncomplete(blockers: [String])
    /// reload_acked_at 门禁（§5.4-2）：Capture One 尚未确认重载元数据。
    ///
    /// 码值沿用旧 UI 认得的 XMP_CONFIRM_REQUIRES_SYNC：S5c-2a 之前 confirm/finalize
    /// 在「不能收口」时抛的就是这个码；旧的 XMP_RELOAD_NOT_ACKED 仍由
    /// MetadataSyncCoordinator 保留（S5c-2b-3 删除旧链路后自然消失）。
    case reloadNotAcknowledged(sessionId: String)
    /// cleanup 的备份文件不存在（不删 DB、不误删侧车）。
    case backupMissing(xmpPath: String)
    /// 回放时 payload_json 缺字段/损坏。
    case invalidPayload(intentId: Int64, reason: String)
    /// 调用参数非法。
    case invalidArgument(String)
    /// 文件阶段已按旧快照执行，但 await 期间交付已被新输入/重写推进（P0-1）。
    /// 旧备份可能已覆盖新内容，必须显式上报并放弃 intent，不得静默当成功。
    case filePhaseInvalidated(xmpPath: String, reason: String)

    public var code: String {
        switch self {
        case .confirmIncomplete: return "XMP_CONFIRM_INCOMPLETE"
        case .reloadNotAcknowledged: return "XMP_CONFIRM_REQUIRES_SYNC"
        case .backupMissing: return "XMP_BACKUP_MISSING"
        case .invalidPayload: return "XMP_CLEANUP_INVALID_PAYLOAD"
        case .invalidArgument: return "DELIVERY_COORDINATOR_INVALID_ARGUMENT"
        case .filePhaseInvalidated: return "XMP_CLEANUP_FILE_PHASE_INVALIDATED"
        }
    }

    public var description: String {
        switch self {
        case .confirmIncomplete(let blockers):
            return "\(code): " + blockers.joined(separator: ",")
        case .reloadNotAcknowledged(let sessionId):
            return "\(code): \(sessionId)"
        case .backupMissing(let xmpPath):
            return "\(code): \(xmpPath)"
        case .invalidPayload(let intentId, let reason):
            return "\(code): #\(intentId) \(reason)"
        case .invalidArgument(let message):
            return "\(code): \(message)"
        case .filePhaseInvalidated(let xmpPath, let reason):
            return "\(code): \(xmpPath) reason=\(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// cleanup 的逐交付结果。errors 与 conflicted/skipped 分开，调用方可只对 errors 重试。
public struct DeliveryCleanupSummary: Sendable, Equatable {
    /// 真正删除了 deliveries 行的数量。
    public let deletedCount: Int
    /// 检测到外部修改、已标 conflict 且未删除的数量。
    public let conflictedCount: Int
    /// 未到 synced/已有未完成 intent/revision 已变等「本轮不处理」的数量。
    public let skippedCount: Int
    /// 可重试的失败（文件/DB/intent 写入），对应 intent 被保留。
    public let errors: [String]
    /// 检测到外部修改、已标 conflict 的侧车路径（按发现顺序）。
    /// 与 errors 分开：冲突不是「可重试失败」，而是需要用户裁决的外部修改；
    /// 调用方（如 CullingService.cleanup）据此把冲突按路径回填到旧 CleanupResult.errors。
    public let conflictedXmpPaths: [String]

    public init(
        deletedCount: Int,
        conflictedCount: Int,
        skippedCount: Int,
        errors: [String],
        conflictedXmpPaths: [String] = []
    ) {
        self.deletedCount = deletedCount
        self.conflictedCount = conflictedCount
        self.skippedCount = skippedCount
        self.errors = errors
        self.conflictedXmpPaths = conflictedXmpPaths
    }
}

/// 启动回放结果。
public struct DeliveryReplaySummary: Sendable, Equatable {
    /// 成功闭环（intent 删除）的数量。
    public let appliedCount: Int
    /// 因 revision/状态已变而终止（intent 标 applied + error）的数量。
    public let skippedCount: Int
    /// 仍保留 intent、下次 replay() 可重试的数量。
    public let failedCount: Int
    public let errors: [String]

    public init(
        appliedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        errors: [String]
    ) {
        self.appliedCount = appliedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.errors = errors
    }
}

/// finalize（dropWithoutRestore）的逐交付结果。
/// 与 cleanup 的区别：文件阶段只删除备份，绝不 restore；冲突交付不是候选（只处理 synced）。
public struct DeliveryFinalizeSummary: Sendable, Equatable {
    /// 真正删除了 deliveries 行的数量。
    public let deletedCount: Int
    /// 状态已变/已有未完成 intent/revision 已变等「本轮不处理」的数量。
    public let skippedCount: Int
    /// 可重试的失败（文件/DB/intent 写入），对应 intent 被保留。
    public let errors: [String]

    public init(deletedCount: Int, skippedCount: Int, errors: [String]) {
        self.deletedCount = deletedCount
        self.skippedCount = skippedCount
        self.errors = errors
    }
}

/// 旧 WritebackService 的执行结果 → 交付镜像的窄输入（S5c-2b-1 过渡双写）。
///
/// 为什么不让 coordinator 读 MetadataOutboxRow：outbox 是 S5c-2b-3 要删的旧模型；
/// 基线/备份路径由 CullingService 在过渡期从 outbox 抄出后显式传入，coordinator
/// 不反向依赖旧仓储。
public struct DeliveryWritebackMirrorItem: Sendable, Equatable {
    public let photoId: String
    public let photoPath: String
    public let xmpPath: String
    /// 写盘后的关键词（已合并既有词与计划词）。
    public let keywords: [String]
    /// rating/label 等结构化属性（keywords 已单列，不重复写入）。
    public let attributes: [String: JSONValue]
    /// 只允许 .written / .failed（pending 表示没执行，不镜像）。
    public let status: DeliveryItemStatus
    public let errorMessage: String
    public let backupPath: String
    public let baseFingerprint: String
    public let baseValues: JSONValue

    public init(
        photoId: String,
        photoPath: String,
        xmpPath: String,
        keywords: [String],
        attributes: [String: JSONValue] = [:],
        status: DeliveryItemStatus,
        errorMessage: String = "",
        backupPath: String = "",
        baseFingerprint: String = "",
        baseValues: JSONValue = .object([:])
    ) {
        self.photoId = photoId
        self.photoPath = photoPath
        self.xmpPath = xmpPath
        self.keywords = keywords
        self.attributes = attributes
        self.status = status
        self.errorMessage = errorMessage
        self.backupPath = backupPath
        self.baseFingerprint = baseFingerprint
        self.baseValues = baseValues
    }
}

/// 写回镜像结果（按交付分组后的计数 + 可重试/可诊断错误）。
public struct DeliveryMirrorSummary: Sendable, Equatable {
    public let deliveryCount: Int
    public let itemCount: Int
    public let errors: [String]

    public init(deliveryCount: Int, itemCount: Int, errors: [String]) {
        self.deliveryCount = deliveryCount
        self.itemCount = itemCount
        self.errors = errors
    }
}

/// 写回基线（S5c-2b-3b-2a）：执行器已把真实备份/指纹/基线直接写进 deliveries，
/// 镜像（Culling/FaceKw/Similarity 的 execute 后置步骤）只回读同一行，不再从
/// metadata_outbox 抄（旧表随 2b 删除，本类型保留为镜像的窄输入）。
public struct DeliveryWritebackBaseline: Sendable, Equatable {
    public let backupPath: String
    public let baseFingerprint: String
    public let baseValues: JSONValue

    static let empty = DeliveryWritebackBaseline(
        backupPath: "", baseFingerprint: "", baseValues: .object([:])
    )
}

/// 按 xmpPath 读交付行上的基线；行不存在 → 空基线（不阻塞镜像）。
/// 不抛错：镜像失败可回退为空基线，绝不让"读不到基线"伪造成写盘失败。
public func deliveryWritebackBaseline(
    connection: DBConnection,
    xmpPath: String
) -> DeliveryWritebackBaseline {
    do {
        guard let row = try DeliveryRepo(connection: connection).get(xmpPath) else {
            return .empty
        }
        return DeliveryWritebackBaseline(
            backupPath: row.backupPath,
            baseFingerprint: row.baseFingerprint,
            baseValues: row.baseValues
        )
    } catch {
        GatherLogger.log(
            "delivery writeback baseline unavailable (\(xmpPath)): \(error)",
            level: .debug
        )
        return .empty
    }
}

/// 仅文件系统的 DeliveryFilePort（测试用替身；生产默认注入 XMPDeliveryFilePort）。
///
/// 恢复 = 备份覆盖写回 photo.xmp（幂等），删除 = unlink。宿主一律经 XMPProvider
/// 注入 XMPDeliveryFilePort（原子替换 + 大小写侧车解析）。
public struct FileSystemDeliveryFilePort: DeliveryFilePort {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        guard FileManager.default.fileExists(atPath: backupPath) else {
            throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
        }
        let target = TSPath.xmpSidecarPath(photoPath)
        // 先拷到同目录临时文件，再替换目标：中途失败不会把原侧车删空
        //（与 SidecarXMPProvider.install 的覆盖写语义一致）。
        let tempPath = target + ".restore-" + UUID().uuidString.lowercased()
        try FileManager.default.copyItem(atPath: backupPath, toPath: tempPath)
        do {
            if FileManager.default.fileExists(atPath: target) {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: target),
                    withItemAt: URL(fileURLWithPath: tempPath)
                )
            } else {
                try FileManager.default.moveItem(atPath: tempPath, toPath: target)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    public func removeFile(_ path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
