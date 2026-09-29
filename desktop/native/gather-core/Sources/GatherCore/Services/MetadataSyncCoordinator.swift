// desktop/native/gather-core/Sources/GatherCore/Services/MetadataSyncCoordinator.swift
// 写回内核的唯一协调器（R4 重写）。
//
// 真相源与顺序：
//   变更（MetadataMutationService）→ metadata_outbox 行（先落库）
//     → 本协调器 claim 租约 → XMP provider 写盘（唯一写入路径）→ markWritten
//   任何绕过 provider 直接改 XMP 的路径都已被删除；任何"先写盘后落库"的顺序都不存在。
//
// 状态机（MetadataOutboxStatus，见 MetadataOutboxRepo）：
//   pending → writing → written → synced →（cleanup/finalize 删除）
//                 ↓失败            ↓外部修改
//               failed ←→ pending   conflict → pending / 删除
//   writing 是租约态：进程启动 recoverInterrupted 全量归位；运行期每轮 drain 回收过期租约。
//   => writing 永远有出口，"必须由调用方记得先 start()"的隐式契约已被取消（首次使用即恢复）。
//
// 错误：一律经 MetadataWritebackFailure 落库为「稳定错误码 + xmpPath + 字段 + 原因」，
// UI 报告卡可渲染错误码与路径（不再是 NSError 散文）。
//
// 并发：本类的可变调度状态由 lock 保护；写并发上限 2（SlotGate）；同一 xmpPath 单飞。

import Foundation

/// 宿主 XMP provider 的错误可被内核结构化的最小面（gather-app 的 SidecarXMPError 已实现）。
public protocol MetadataCodedError: Error, Sendable {
    var code: String { get }
    var xmpPath: String { get }
    /// 结构化字段名（rating/label/keywords）；nil = 整行或非字段级失败。
    var field: String? { get }
}

public extension MetadataCodedError {
    var field: String? { nil }
}

/// 落库的失败记录：稳定错误码 + 结构化字段。
public struct MetadataWritebackFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let xmpPath: String
    public let field: String?
    public let reason: String

    public init(code: String, xmpPath: String, field: String?, reason: String) {
        self.code = code
        self.xmpPath = xmpPath
        self.field = field
        self.reason = reason
    }

    /// 任意 Error → 类型化失败记录（优先宿主投递的错误码/字段，其次是内核错误码）。
    /// - Parameter fallbackField: 调用方已知的字段名兜底（如单字段行的 dirty field）。
    public static func from(
        _ error: Error,
        xmpPath: String,
        field fallbackField: String? = nil
    ) -> MetadataWritebackFailure {
        if let coded = error as? any MetadataCodedError {
            return MetadataWritebackFailure(
                code: coded.code,
                xmpPath: coded.xmpPath.isEmpty ? xmpPath : coded.xmpPath,
                field: coded.field ?? fallbackField,
                reason: String(describing: error))
        }
        if let sync = error as? MetadataSyncError {
            // 落库 code 用精确错误码（不再拼 description）；reason 保留可读细节（如阻塞会话 id）。
            return MetadataWritebackFailure(
                code: sync.gatherCode.rawValue,
                xmpPath: xmpPath,
                field: fallbackField,
                reason: sync.description)
        }
        if let outbox = error as? MetadataOutboxError {
            return MetadataWritebackFailure(code: outbox.code, xmpPath: xmpPath, field: nil, reason: String(describing: error))
        }
        if error is MetadataFingerprintError {
            return MetadataWritebackFailure(
                code: "XMP_FINGERPRINT_FAILED", xmpPath: xmpPath, field: nil,
                reason: String(describing: error))
        }
        return MetadataWritebackFailure(
            code: "XMP_WRITE_FAILED", xmpPath: xmpPath, field: nil, reason: String(describing: error))
    }

    public var description: String {
        var text = code + ": " + xmpPath
        if let field { text += " field=" + field }
        text += " reason=" + reason
        return text
    }
}

/// TS: metadata-sync-coordinator.ts 抛出的全部错误码（description 与 TS 逐字一致）。
public enum MetadataSyncError: Error, Equatable, CustomStringConvertible {
    case conflictResolutionRequired // XMP_CONFLICT_RESOLUTION_REQUIRED
    case confirmIncomplete // XMP_CONFIRM_INCOMPLETE
    case cleanupRequiresLoaded // XMP_CLEANUP_REQUIRES_LOADED
    case confirmRequiresSync // XMP_CONFIRM_REQUIRES_SYNC
    case externallyModified // XMP_EXTERNALLY_MODIFIED
    case backupMissing // XMP_BACKUP_MISSING
    case cleanupAbortedExternalEdit // XMP_CLEANUP_ABORTED_EXTERNAL_EDIT
    case externalEditConflict // XMP_EXTERNAL_EDIT_CONFLICT
    case reloadNotAcked // XMP_RELOAD_NOT_ACKED
    case conflictNotFound // XMP_CONFLICT_NOT_FOUND
    case conflictDetailsUnavailable // XMP_CONFLICT_DETAILS_UNAVAILABLE
    case choiceMissing // XMP_CHOICE_MISSING
    case conflictDetailsInvalid // XMP_CONFLICT_DETAILS_INVALID
    /// 同一侧车被多个会话共享，且（除当前会话外的）关联会话尚未确认。
    /// 关联会话 id 放在 description 之外（结构化）：见 confirmSync 抛错时的参数。
    case otherSessionNotConfirmed(sessionId: String) // XMP_CONFIRM_OTHER_SESSION_PENDING
    case orphanNotFound // XMP_ORPHAN_NOT_FOUND
    case orphanNotRetryable // XMP_ORPHAN_NOT_RETRYABLE
    case writerTimeout // XMP_WRITER_TIMEOUT

    public var description: String {
        switch self {
        case .conflictResolutionRequired: "XMP_CONFLICT_RESOLUTION_REQUIRED"
        case .confirmIncomplete: "XMP_CONFIRM_INCOMPLETE"
        case .cleanupRequiresLoaded: "XMP_CLEANUP_REQUIRES_LOADED"
        case .confirmRequiresSync: "XMP_CONFIRM_REQUIRES_SYNC"
        case .externallyModified: "XMP_EXTERNALLY_MODIFIED"
        case .backupMissing: "XMP_BACKUP_MISSING"
        case .cleanupAbortedExternalEdit: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT"
        case .externalEditConflict: "XMP_EXTERNAL_EDIT_CONFLICT"
        case .reloadNotAcked: "XMP_RELOAD_NOT_ACKED"
        case .conflictNotFound: "XMP_CONFLICT_NOT_FOUND"
        case .conflictDetailsUnavailable: "XMP_CONFLICT_DETAILS_UNAVAILABLE"
        case .choiceMissing: "XMP_CHOICE_MISSING"
        case .conflictDetailsInvalid: "XMP_CONFLICT_DETAILS_INVALID"
        case .otherSessionNotConfirmed(let sessionId): "XMP_CONFIRM_OTHER_SESSION_PENDING: " + sessionId
        case .orphanNotFound: "XMP_ORPHAN_NOT_FOUND"
        case .orphanNotRetryable: "XMP_ORPHAN_NOT_RETRYABLE"
        case .writerTimeout: "XMP_WRITER_TIMEOUT"
        }
    }

    /// 本地化漏斗：每个错误码都映射到 GatherErrorCode（UI 不再解析 description 字符串）。
    public var gatherCode: GatherErrorCode {
        switch self {
        case .conflictResolutionRequired: .XMP_CONFLICT_RESOLUTION_REQUIRED
        case .confirmIncomplete: .XMP_CONFIRM_INCOMPLETE
        case .cleanupRequiresLoaded: .XMP_CLEANUP_REQUIRES_LOADED
        case .confirmRequiresSync: .XMP_CONFIRM_REQUIRES_SYNC
        case .otherSessionNotConfirmed: .XMP_CONFIRM_OTHER_SESSION_PENDING
        case .externallyModified: .XMP_EXTERNALLY_MODIFIED
        case .backupMissing: .XMP_BACKUP_MISSING
        case .cleanupAbortedExternalEdit: .XMP_CLEANUP_ABORTED_EXTERNAL_EDIT
        case .externalEditConflict: .XMP_EXTERNAL_EDIT_CONFLICT
        case .reloadNotAcked: .XMP_RELOAD_NOT_ACKED
        case .conflictNotFound: .XMP_CONFLICT_NOT_FOUND
        case .conflictDetailsUnavailable: .XMP_CONFLICT_DETAILS_UNAVAILABLE
        case .choiceMissing: .XMP_CHOICE_MISSING
        case .conflictDetailsInvalid: .XMP_CONFLICT_DETAILS_INVALID
        case .orphanNotFound: .XMP_ORPHAN_NOT_FOUND
        case .orphanNotRetryable: .XMP_ORPHAN_NOT_RETRYABLE
        case .writerTimeout: .XMP_WRITER_TIMEOUT
        }
    }
}

/// WritebackService / CullingService 依赖的协调器最小面。
public protocol MetadataSyncPort: Sendable {
    func waitForIdle(xmpPath: String, timeoutMs: Int) async throws
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary
    func confirmSync(sessionId: String, sourceModule: String) throws -> MetadataSyncSummary
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult
}

/// 写回协调器。
/// 线程安全说明（Swift 6 `Sendable`）：全部可变状态（`timers`/`queued`/`queuedSet`/
/// `active`/`baselineTasks`/`summaryEmitTimers`/`summaryEmitCounts`/`stopped`/
/// `startupRecoveryDone`）都在 `lock`（NSLock）临界区内，`_eventSink` 由 `eventSinkLock` 保护，
/// 其余存储属性构造后不可变。锁纪律无法被编译器静态验证，故标注 `@unchecked`
/// （与同文件 `SlotGate`、`BatchCursor` 的既有约定一致）。
public final class MetadataSyncCoordinator: MetadataSyncPort, @unchecked Sendable {
    /// TS: MAX_CONCURRENCY。
    public static let maxConcurrency = 2
    /// TS: MAX_AUTOMATIC_ATTEMPTS（与仓库共享同一常量）。
    public static let maxAutomaticAttempts = MetadataSyncLimits.maxAutomaticAttempts
    /// TS: RETRY_DELAYS_MS。
    public static let retryDelaysMs = MetadataSyncLimits.retryDelaysMs
    /// TS: SUMMARY_EMIT_THROTTLE_MS。
    public static let summaryEmitThrottleMs = 100
    /// TS: SUMMARY_EMIT_BURST_THRESHOLD。
    public static let summaryEmitBurstThreshold = 50
    /// TS: settings.getNumber('metadata_write_debounce_ms', 500)。
    public static let defaultWriteDebounceMs = 500
    /// waitForIdle 默认超时（5000ms）。
    public static let defaultWaitTimeoutMs = 5_000
    /// writing 租约窗口（超过即可被安全重新 claim）。
    public static let writingLeaseMs = MetadataOutboxRepo.defaultLeaseMs

    private let outboxRepo: MetadataOutboxRepo
    private let writebackRepo: WritebackRepo
    private let xmp: any XMPProvider
    private let getNumber: (String, Double) -> Double
    private let connection: DBConnection
    /// TS: process.env.GATHER_TEST_SKIP_RELOAD_ACK === '1'。
    public let skipReloadAck: Bool

    private let eventSinkLock = NSLock()
    private var _eventSink: ((MetadataSyncSummary) -> Void)?
    public var eventSink: ((MetadataSyncSummary) -> Void)? {
        get { eventSinkLock.withLock { _eventSink } }
        set { eventSinkLock.withLock { _eventSink = newValue } }
    }

    private let lock = NSLock()
    private var timers: [String: Task<Void, Never>] = [:]
    private var queued: [String] = []
    private var queuedSet: Set<String> = []
    private var active: [String: Task<Void, Never>] = [:]
    private var baselineTasks: [String: Task<Void, Never>] = [:]
    private var summaryEmitTimers: [String: Task<Void, Never>] = [:]
    private var summaryEmitCounts: [String: Int] = [:]
    private var stopped = false
    private var startupRecoveryDone = false
    private let slotGate = SlotGate(max: MetadataSyncCoordinator.maxConcurrency)

    public init(
        outboxRepo: MetadataOutboxRepo,
        writebackRepo: WritebackRepo,
        xmp: any XMPProvider,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        skipReloadAck: Bool = false
    ) {
        self.outboxRepo = outboxRepo
        self.writebackRepo = writebackRepo
        self.xmp = xmp
        self.connection = connection
        self.getNumber = getNumber
        self.skipReloadAck = skipReloadAck
    }

    // MARK: - 公开 API

    /// 组合根接线：设置摘要回调并立即执行一次恢复 + 重排。
    /// 注意：恢复不依赖本调用（首次使用时也会执行），本方法只是让启动即恢复显式化。
    public func start(eventSink: ((MetadataSyncSummary) -> Void)? = nil) {
        lock.lock()
        stopped = false
        lock.unlock()
        if let eventSink { self.eventSink = eventSink }
        ensureRecovery()
    }

    /// 排程一次写入；取消旧计时器并失效 reload-ack。
    public func schedule(xmpPath: String, delayMs: Int? = nil) {
        let stoppedNow = { lock.lock(); defer { lock.unlock() }; return stopped }()
        if stoppedNow { return }
        // 恢复也挂在最高频入口上：并发/崩溃残留不会因为"没人先调 start()"而卡住。
        // （ensureRecovery 幂等；其内部对恢复行的 schedule 递归到这里时 startup 分支已关闭。）
        ensureRecovery()
        let path = MetadataOutboxPath.normalize(xmpPath)
        // 新写入活动 → 会话 reload-ack 失效（cleanup 不得恢复 C1 从未加载过的备份）。
        clearReloadAckForXmpPath(path)
        Task { [weak self] in
            guard let self else { return }
            await self.ensureBaseline(path)
        }
        let delay = delayMs ?? max(0, getNumber("metadata_write_debounce_ms", Double(MetadataSyncCoordinator.defaultWriteDebounceMs)).safeInt(fallback: MetadataSyncCoordinator.defaultWriteDebounceMs))
        lock.lock()
        timers[path]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000)
            guard let self else { return }
            await self.ensureBaseline(path)
            self.enqueueQueued(path)
            self.drain()
        }
        timers[path] = task
        lock.unlock()
    }

    /// 轻投影 + 分组计数（真实计数，不做乐观修正）。
    public func getSummary(sessionId: String) throws -> MetadataSyncSummary {
        ensureRecovery()
        let rows = try outboxRepo.getSummaryRowsBySession(sessionId)
        let items: [MetadataSyncItem] = rows.map { row in
            MetadataSyncItem(
                xmpPath: row.xmpPath,
                revision: Int(row.revision),
                persistedRevision: Int(row.persistedRevision),
                status: MetadataSyncStatus(rawValue: row.status) ?? .pending,
                attemptCount: Int(row.attemptCount),
                errorMessage: row.errorMessage,
                updatedAt: row.updatedAt
            )
        }
        let counts = try outboxRepo.countBySession(sessionId)
        func count(_ status: String) -> Int {
            if let c = counts[status] { return Int(c) }
            return items.filter { $0.status.rawValue == status }.count
        }
        return MetadataSyncSummary(
            sessionId: sessionId,
            pending: count("pending"),
            writing: count("writing"),
            written: count("written"),
            failed: count("failed"),
            conflict: count("conflict"),
            synced: count("synced"),
            items: items
        )
    }

    /// 冲突列表：可裁决字段来自行内持久数据（dirty/local/remote 快照），文件读不到也不为空。
    public func getConflicts(sessionId: String) async throws -> [MetadataConflict] {
        ensureRecovery()
        let rows = try outboxRepo.getBySession(sessionId).filter { $0.status == "conflict" }
        var result: [MetadataConflict] = []
        for row in rows {
            let dirty = MetadataConflictFields.parseDirtyFields(row.dirtyFields)
            let base = safeObject(row.baseValuesJSON)
            let local = safeObject(row.patchJSON)
            let remote: MetadataWriteAttributes
            if let snapshot = row.remoteSnapshot {
                remote = MetadataWriteAttributes(jsonValue: snapshot)
            } else if let live = try? await xmp.readAttributes(photoPath: row.photoPath) {
                remote = live
            } else {
                remote = MetadataWriteAttributes()
            }
            var fields = MetadataConflictFields.fieldConflicts(
                base: base, local: local, current: remote, dirtyFields: dirty)
            // 无字段级差异也必须给出可裁决项：冲突行必然有 dirty 字段与出口。
            for field in dirty where !fields.contains(where: { $0.field == field }) {
                fields.append(MetadataConflictField(
                    field: field,
                    baseline: .null,
                    local: local[field.rawValue] ?? .null,
                    remote: remote.asJSONValue[field.rawValue] ?? .null))
            }
            result.append(MetadataConflict(
                xmpPath: row.xmpPath, photoPath: row.photoPath,
                revision: Int(row.revision), fields: fields))
        }
        return result
    }

    /// 冲突裁决。三条出口都能离开 conflict：
    /// - 逐字段 use_remote → 该字段丢弃；全部丢弃 → 结清删行（保留磁盘上的远程值）。
    /// - 逐字段 keep_local（或 choices 为空 = 显式结清）→ 以当前磁盘状态为新基线重写本地值。
    /// - 行内快照缺失/文件不可读时依然可裁决（不抛 conflictDetailsUnavailable）。
    public func resolveConflict(
        sessionId: String,
        xmpPath: String,
        choices: [MetadataField: MetadataConflictChoice]
    ) async throws -> MetadataSyncSummary {
        ensureRecovery()
        let path = MetadataOutboxPath.normalize(xmpPath)
        let rows = try outboxRepo.getBySession(sessionId)
        guard let row = rows.first(where: { $0.xmpPath == path || $0.xmpPath == xmpPath }),
              row.status == "conflict" else {
            throw MetadataSyncError.conflictNotFound
        }
        guard let dirtyFields = MetadataConflictFields.tryParseDirtyFields(row.dirtyFields) else {
            throw MetadataSyncError.conflictDetailsInvalid
        }
        if !choices.isEmpty {
            for field in dirtyFields where choices[field] == nil {
                throw MetadataSyncError.choiceMissing
            }
            for (field, _) in choices where !dirtyFields.contains(field) {
                // 未知字段的裁决无意义但不得静默：直接按不存在处理并在摘要中体现真实计数。
                GatherLogger.log("Ignoring conflict choice for untouched field \(field.rawValue) at \(path)", level: .warn)
            }
        }
        let remote: MetadataWriteAttributes
        if let snapshot = row.remoteSnapshot {
            remote = MetadataWriteAttributes(jsonValue: snapshot)
        } else if let live = try? await xmp.readAttributes(photoPath: row.photoPath) {
            remote = live
        } else {
            remote = MetadataWriteAttributes()
        }

        var patch = safeObject(row.patchJSON)
        var remaining = dirtyFields
        for (field, choice) in choices where choice == .useRemote {
            if case .object(var dict) = patch {
                dict.removeValue(forKey: field.rawValue)
                patch = .object(dict)
            }
            remaining.removeAll { $0 == field }
        }
        if remaining.isEmpty {
            // 接受远程：结清事务，并把本地投影同步为磁盘真实值。
            _ = try writebackRepo.discardPendingByXmpPath(xmpPath: row.xmpPath)
            syncAcceptedRemoteValues(photoPath: row.photoPath, remote: remote)
            try outboxRepo.resolveConflict(
                xmpPath: row.xmpPath, patch: patch, dirtyFields: [],
                baselineFingerprint: row.baseFingerprint,
                baselineValues: remote.asJSONValue,
                acceptRemote: true)
            return try emitSummary(sessionId: sessionId)
        }
        // 保留本地：把当前磁盘状态（或快照）设为新基线后重写。
        let currentFingerprint = (try? await MetadataFingerprint.contentFingerprint(row.xmpPath)) ?? ""
        let liveAttributes = try? await xmp.readAttributes(photoPath: row.photoPath)
        let baselineValues: JSONValue = liveAttributes?.asJSONValue ?? remote.asJSONValue
        try outboxRepo.resolveConflict(
            xmpPath: row.xmpPath, patch: patch, dirtyFields: remaining.map(\.rawValue),
            baselineFingerprint: currentFingerprint.isEmpty ? "__missing__" : currentFingerprint,
            baselineValues: baselineValues,
            acceptRemote: false)
        schedule(xmpPath: row.xmpPath, delayMs: 0)
        return try emitSummary(sessionId: sessionId)
    }

    /// TS: listOrphans。
    public func listOrphans() throws -> [MetadataOrphan] {
        ensureRecovery()
        return try outboxRepo.getOrphans().map { row in
            MetadataOrphan(
                xmpPath: row.xmpPath,
                photoPath: row.photoPath,
                status: row.status,
                revision: Int(row.revision),
                errorMessage: row.errorMessage,
                updatedAt: row.updatedAt
            )
        }
    }

    /// TS: resolveOrphan（'keep' | 'restore' | 'retry'）。
    public func resolveOrphan(xmpPath: String, action: MetadataOrphanAction) async throws -> [MetadataOrphan] {
        ensureRecovery()
        let path = MetadataOutboxPath.normalize(xmpPath)
        let row = try outboxRepo.getOrphans().first { $0.xmpPath == path || $0.xmpPath == xmpPath }
        guard let row else { throw MetadataSyncError.orphanNotFound }
        if action == .retry {
            if row.status == "conflict" { throw MetadataSyncError.conflictResolutionRequired }
            if row.status == "failed" {
                try outboxRepo.resetForRetry(row.xmpPath)
            } else if row.status != "pending" {
                throw MetadataSyncError.orphanNotRetryable
            }
            schedule(xmpPath: row.xmpPath, delayMs: 0)
            return try listOrphans()
        }
        try await waitForIdle(xmpPath: row.xmpPath, timeoutMs: MetadataSyncCoordinator.defaultWaitTimeoutMs)
        if action == .restore {
            if !row.backupPath.isEmpty {
                guard xmp.fileExists(row.backupPath) else {
                    GatherLogger.log("XMP backup is missing for orphan restore: \(row.backupPath)", level: .warn)
                    throw MetadataSyncError.backupMissing
                }
                try await xmp.restore(photoPath: row.photoPath, backupPath: row.backupPath)
            } else if xmp.fileExists(row.xmpPath) {
                try await xmp.removeFile(row.xmpPath)
            }
        }
        try outboxRepo.delete(row.xmpPath)
        // 备份文件在行删除成功之后清理（同 finalize：避免删备份成功 + 删行失败 → 永久 backupMissing）。
        removeBackupBestEffort(row.backupPath)
        return try listOrphans()
    }

    /// 整会话 flush：逐行隔离，任何单行失败都不影响其它行（结果取真实 summary）。
    public func flushSession(sessionId: String) async throws -> MetadataSyncSummary {
        ensureRecovery()
        let paths = try outboxRepo.getBySession(sessionId)
            .filter { ["pending", "writing", "failed", "conflict"].contains($0.status) }
            .map(\.xmpPath)
        cancelTimers(paths: paths)
        // conflict 行不写盘但必须先离开 writing/失败态：交给租约恢复与裁决出口。
        let tasks = paths.filter { path in
            (try? outboxRepo.get(path))?.status != "conflict"
        }.map { runPath($0) }
        await withTaskGroup(of: Void.self) { group in
            for task in tasks { group.addTask { await task.value } }
            await group.waitForAll()
        }
        return try getSummary(sessionId: sessionId)
    }

    /// 失败行整体重排后 flush（真实结果）。
    public func retrySession(sessionId: String) async throws -> MetadataSyncSummary {
        ensureRecovery()
        for row in try outboxRepo.getBySession(sessionId) where row.status == "failed" {
            try outboxRepo.resetForRetry(row.xmpPath)
            clearReloadAckForXmpPath(row.xmpPath)
        }
        return try await flushSession(sessionId: sessionId)
    }

    /// 会话确认：返回真实计数；有未完成行时抛 XMP_CONFIRM_INCOMPLETE（不谎报成功）。
    public func confirmSync(sessionId: String, sourceModule: String) throws -> MetadataSyncSummary {
        ensureRecovery()
        let summary = try getSummary(sessionId: sessionId)
        if summary.pending > 0 || summary.writing > 0 || summary.failed > 0 || summary.conflict > 0 {
            throw MetadataSyncError.confirmIncomplete
        }
        try requireReloadAck(sessionId)
        // 跨会话门：同一侧车可能被多个会话共享（§11 双会话）。任一关联会话未确认时，
        // markSessionSynced 不会把行推进 synced —— 若此处仍返回成功，用户会被误导，
        // 且 cleanup 恒抛 XMP_CLEANUP_REQUIRES_LOADED（行永远停在 written）。
        // 因此：显式不完整 + 指名阻塞会话（不返回成功）。裁决/修复出口：
        //   另一会话完成 confirmSync（其自身需 reload-ack）→ 行才转 synced。
        // 本会话的确认先落地（进度可累积，避免"谁都无法先确认"的死锁）；
        // 随后只认真实结果：只要还有 written 行就**不返回成功**。
        try outboxRepo.markSessionSynced(sessionId: sessionId, sourceModule: sourceModule)
        let after = try getSummary(sessionId: sessionId)
        if after.written > 0 {
            let blockers = try outboxRepo.unconfirmedLinkedSessions(
                sessionId: sessionId, requireReloadAck: !skipReloadAck)
            if let blocker = blockers.first {
                throw MetadataSyncError.otherSessionNotConfirmed(sessionId: blocker)
            }
            throw MetadataSyncError.confirmIncomplete
        }
        return try emitSummary(sessionId: sessionId)
    }

    /// 清理：逐行隔离 + 真实删除计数与逐行失败原因（synced 行的唯一删除出口）。
    public func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
        ensureRecovery()
        let rows = try outboxRepo.getBySession(sessionId)
        let eligible = rows.filter { $0.status == "synced" && $0.isOwned(byModule: sourceModule) }
        if eligible.isEmpty && !rows.isEmpty {
            throw MetadataSyncError.cleanupRequiresLoaded
        }
        if !eligible.isEmpty { try requireReloadAck(sessionId) }
        let results = try await batchAsync(eligible, concurrency: MetadataSyncCoordinator.maxConcurrency) { row -> (deleted: Bool, error: String?) in
            do {
                try await self.waitForIdle(xmpPath: row.xmpPath, timeoutMs: MetadataSyncCoordinator.defaultWaitTimeoutMs)
                guard let latest = try self.outboxRepo.get(row.xmpPath), latest.status == "synced" else {
                    return (false, nil)
                }
                let currentFingerprint = try await MetadataFingerprint.contentFingerprint(latest.xmpPath)
                if !latest.baseFingerprint.isEmpty && currentFingerprint != latest.baseFingerprint {
                    let remote = (try? await self.xmp.readAttributes(photoPath: latest.photoPath)) ?? MetadataWriteAttributes()
                    _ = try? self.outboxRepo.markConflict(
                        xmpPath: latest.xmpPath, remote: remote.asJSONValue,
                        reason: MetadataSyncError.cleanupAbortedExternalEdit.description)
                    throw MetadataSyncError.externallyModified
                }
                if !latest.backupPath.isEmpty {
                    guard self.xmp.fileExists(latest.backupPath) else { throw MetadataSyncError.backupMissing }
                    // 顺序（幂等可重试）：restore 是拷贝语义且不消费备份 → 删行失败可原样重试。
                    try await self.xmp.restore(photoPath: latest.photoPath, backupPath: latest.backupPath)
                    try self.outboxRepo.delete(latest.xmpPath)
                    // 行已删除后才清理备份文件；失败只留下无引用文件（日志可见），不回滚。
                    self.removeBackupBestEffort(latest.backupPath)
                } else if self.xmp.fileExists(latest.xmpPath) {
                    try await self.xmp.removeFile(latest.xmpPath)
                    try self.outboxRepo.delete(latest.xmpPath)
                } else {
                    try self.outboxRepo.delete(latest.xmpPath)
                }
                return (true, nil)
            } catch {
                return (false, MetadataWritebackFailure.from(error, xmpPath: row.xmpPath).description)
            }
        }
        var deletedCount = 0
        var errors: [String] = []
        for result in results {
            if result.deleted { deletedCount += 1 }
            else if let error = result.error { errors.append(error) }
        }
        _ = try? emitSummary(sessionId: sessionId)
        return CleanupResult(deletedCount: deletedCount, errors: errors)
    }

    /// 收尾（带真实计数）：revision 守卫删除行 → 清理备份文件。
    /// 顺序刻意与旧实现相反：先删备份会让"删行失败"的行永久 backupMissing；
    /// 先删行则删备份失败只留下无引用文件（幂等：重复收尾只会少删一次文件）。
    @discardableResult
    public func finalizeSessionReporting(sessionId: String) async throws -> CleanupResult {
        ensureRecovery()
        let rows = try outboxRepo.getBySession(sessionId)
        let eligible = rows.filter { $0.status == "synced" }
        if eligible.isEmpty && !rows.isEmpty {
            throw MetadataSyncError.confirmRequiresSync
        }
        let results = try await batchAsync(eligible, concurrency: MetadataSyncCoordinator.maxConcurrency) { row -> (deleted: Bool, error: String?) in
            do {
                try await self.waitForIdle(xmpPath: row.xmpPath, timeoutMs: MetadataSyncCoordinator.defaultWaitTimeoutMs)
                guard let latest = try self.outboxRepo.get(row.xmpPath), latest.status == "synced" else {
                    return (false, nil)
                }
                let backupPath = latest.backupPath
                try self.outboxRepo.deleteByRevision(xmpPath: latest.xmpPath, revision: latest.revision)
                let removed = (try? self.outboxRepo.get(latest.xmpPath)) == nil
                self.removeBackupBestEffort(backupPath)
                return (removed, nil)
            } catch {
                return (false, MetadataWritebackFailure.from(error, xmpPath: row.xmpPath).description)
            }
        }
        var deletedCount = 0
        var errors: [String] = []
        for result in results {
            if result.deleted { deletedCount += 1 }
            else if let error = result.error { errors.append(error) }
        }
        _ = try? emitSummary(sessionId: sessionId)
        return CleanupResult(deletedCount: deletedCount, errors: errors)
    }

    /// 协议兼容入口（CullingSyncPort 声明返回 summary）：委托给带计数的实现。
    public func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary {
        _ = try await finalizeSessionReporting(sessionId: sessionId)
        return try emitSummary(sessionId: sessionId)
    }

    /// 停止：取消计时器并等待所有在飞任务与槽位等待者排空。
    /// 刻意不执行 ensureRecovery：停止路径上恢复会重新排程写入，与"停止"矛盾；
    /// 残留 writing 行由下一次 start/任何公开入口的启动恢复处理（writing 不是终态，无需在此清理）。
    public func shutdown() async {
        stopSchedulingLocked()
        while true {
            let tasks = snapshotTasks()
            if tasks.isEmpty && slotGate.isIdle { break }
            await withTaskGroup(of: Void.self) { group in
                for task in tasks { group.addTask { await task.value } }
                await group.waitForAll()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 等待该路径在飞写入结束（含租约恢复；超时抛 XMP_WRITER_TIMEOUT）。
    public func waitForIdle(xmpPath: String, timeoutMs: Int) async throws {
        // 先做租约恢复：陈旧 writing 行不能在"等待在飞写入"里变成假超时。
        ensureRecovery()
        let path = MetadataOutboxPath.normalize(xmpPath)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let activeTask = activeTask(for: path) { await activeTask.value }
            guard let row = try? outboxRepo.get(path), row.status == "writing" else { return }
            if Date() >= deadline {
                GatherLogger.log("Timed out waiting for metadata writer: \(path)", level: .warn)
                throw MetadataSyncError.writerTimeout
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 恢复（唯一入口，首次使用即执行）

    /// 启动恢复（幂等）：进程启动时不存在任何租约，全部 writing 行归位为 pending 并重排。
    /// 本方法在每个公开入口与每轮 drain 前调用，因此不存在"外部忘记调 start()"的隐式契约。
    private func ensureRecovery() {
        let needsStartup: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return !startupRecoveryDone && !stopped
        }()
        if needsStartup {
            lock.lock()
            startupRecoveryDone = true
            lock.unlock()
            do {
                let recovered = try outboxRepo.recoverInterrupted()
                for path in recovered {
                    GatherLogger.log("Recovered interrupted metadata write \(path) -> pending", level: .warn)
                    schedule(xmpPath: path, delayMs: 0)
                }
                for row in try outboxRepo.getRecoverableActive() {
                    schedule(xmpPath: row.xmpPath, delayMs: 0)
                }
            } catch {
                GatherLogger.log("Metadata outbox startup recovery failed: \(error)", level: .error)
            }
        }
        recoverExpiredLeases()
    }

    /// 运行期租约回收：过期且非本进程在飞的 writing 行归位（pending / failed+原因）。
    private func recoverExpiredLeases() {
        let activePaths = currentActivePaths()
        do {
            let recovered = try outboxRepo.recoverExpiredLeases(
                activePaths: activePaths,
                leaseMs: MetadataSyncCoordinator.writingLeaseMs,
                maxAttempts: MetadataSyncCoordinator.maxAutomaticAttempts)
            for entry in recovered {
                GatherLogger.log(
                    "Metadata lease expired for \(entry.xmpPath) -> \(entry.newStatus.rawValue)", level: .warn)
                if entry.newStatus == .pending { enqueueQueued(entry.xmpPath) }
            }
        } catch {
            GatherLogger.log("Metadata lease recovery failed: \(error)", level: .error)
        }
    }

    private func currentActivePaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(active.keys)
    }

    // MARK: - 调度内部

    private func drain() {
        recoverExpiredLeases()
        while true {
            let next: String? = {
                lock.lock()
                defer { lock.unlock() }
                guard !stopped, !queued.isEmpty else { return nil }
                let nextPath = queued.removeFirst()
                queuedSet.remove(nextPath)
                return nextPath
            }()
            guard let xmpPath = next else { return }
            _ = runPath(xmpPath)
        }
    }

    private func runPath(_ xmpPath: String) -> Task<Void, Never> {
        let path = MetadataOutboxPath.normalize(xmpPath)
        lock.lock()
        if stopped {
            lock.unlock()
            return Task {}
        }
        if let existing = active[path] {
            lock.unlock()
            return existing
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.withSlot {
                await self.processUntilCurrent(path)
            }
            self.finishRun(path)
        }
        active[path] = task
        lock.unlock()
        return task
    }

    private func finishRun(_ xmpPath: String) {
        lock.lock()
        active.removeValue(forKey: xmpPath)
        lock.unlock()
        drain()
    }

    private func withSlot(_ operation: () async -> Void) async {
        await slotGate.acquire()
        defer { slotGate.release() }
        await operation()
    }

    /// 循环处理直至当前 revision 消费完毕（每轮先回收过期租约）。
    private func processUntilCurrent(_ xmpPath: String) async {
        while true {
            recoverExpiredLeases()
            let stoppedNow = { lock.lock(); defer { lock.unlock() }; return stopped }()
            if stoppedNow { return }
            await ensureBaseline(xmpPath)
            guard let row = try? outboxRepo.get(xmpPath),
                  ["pending", "writing", "failed"].contains(row.status) else { return }
            let shouldContinue = await processRow(row)
            if !shouldContinue { return }
            guard let latest = try? outboxRepo.get(xmpPath), latest.status == "pending" else { return }
        }
    }

    /// 单行处理：claim（租约）→ 崩溃窗口补写/冲突检测 → 备份写盘 → markWritten。
    private func processRow(_ row: MetadataOutboxRow) async -> Bool {
        guard (try? outboxRepo.claim(xmpPath: row.xmpPath, expectedRevision: row.revision)) ?? false else {
            return false
        }
        clearReloadAckForXmpPath(row.xmpPath)
        let patch = safeObject(row.patchJSON)
        do {
            let currentFingerprint = try await MetadataFingerprint.contentFingerprint(row.xmpPath)
            let currentToken = currentFingerprint.isEmpty ? "__missing__" : currentFingerprint
            if !row.baseFingerprint.isEmpty, currentToken != row.baseFingerprint {
                let current = try await xmp.readAttributes(photoPath: row.photoPath)
                // 原子 rename 与 markWritten 之间的崩溃：文件已含本次写入 → 补完事务。
                if !row.backupPath.isEmpty, attributesMatchPatch(current, patch) {
                    _ = try outboxRepo.markWritten(
                        xmpPath: row.xmpPath, revision: row.revision, fingerprint: currentToken,
                        baseValues: current.asJSONValue, backupPath: row.backupPath)
                    emitPathSummaries(row.xmpPath)
                    return true
                }
                if hasFieldConflict(row, current: current) {
                    _ = try outboxRepo.markConflict(
                        xmpPath: row.xmpPath, remote: current.asJSONValue,
                        reason: MetadataSyncError.externalEditConflict.description)
                    emitPathSummaries(row.xmpPath)
                    return false
                }
            }

            let backupPath: String
            if !row.backupPath.isEmpty {
                backupPath = row.backupPath
            } else {
                backupPath = try await xmp.backup(photoPath: row.photoPath)
                try outboxRepo.setBackupPath(xmpPath: row.xmpPath, backupPath: backupPath)
            }
            try await xmp.writeAttributes(photoPath: row.photoPath, attributes: MetadataWriteAttributes(
                keywords: patch["keywords"]?.arrayElements?.compactMap { $0.stringValue },
                rating: patch["rating"]?.numberValue,
                label: patch["label"]?.stringValue
            ))
            // 写后回读 + 指纹（provider 内部也已校验；这里落库的是磁盘真实状态）。
            let persistedValues = try await xmp.readAttributes(photoPath: row.photoPath)
            let writtenFingerprint = try await MetadataFingerprint.contentFingerprint(row.xmpPath)
            let applied = try outboxRepo.markWritten(
                xmpPath: row.xmpPath, revision: row.revision, fingerprint: writtenFingerprint,
                baseValues: persistedValues.asJSONValue, backupPath: backupPath)
            if !applied {
                GatherLogger.log("Metadata row superseded while writing: \(row.xmpPath)", level: .warn)
            }
            emitPathSummaries(row.xmpPath)
            return applied
        } catch {
            // 单字段行：把字段名结构化进失败记录（不是只写进 reason 文本）。
            let singleField = row.dirty.count == 1 ? row.dirty[0] : nil
            let failure = MetadataWritebackFailure.from(
                error, xmpPath: row.xmpPath, field: singleField)
            guard let updated = try? outboxRepo.markFailed(xmpPath: row.xmpPath, reason: failure.description) else {
                GatherLogger.log("Failed to record metadata failure for \(row.xmpPath): \(failure)", level: .error)
                return false
            }
            if updated.attemptCount < Int64(MetadataSyncCoordinator.maxAutomaticAttempts) {
                let index = min(max(0, Int(updated.attemptCount) - 1), MetadataSyncCoordinator.retryDelaysMs.count - 1)
                schedule(xmpPath: row.xmpPath, delayMs: MetadataSyncCoordinator.retryDelaysMs[index])
            }
            emitPathSummaries(row.xmpPath)
            return false
        }
    }

    private func hasFieldConflict(_ row: MetadataOutboxRow, current: MetadataWriteAttributes) -> Bool {
        let base = safeObject(row.baseValuesJSON)
        guard let dirtyFields = MetadataConflictFields.tryParseDirtyFields(row.dirtyFields) else {
            // 损坏的 stored dirty-fields 保守地视为冲突。
            return true
        }
        return MetadataConflictFields.hasFieldConflict(base: base, current: current, dirtyFields: dirtyFields)
    }

    /// 单飞基线：行无基线时快照内容指纹与属性基线（失败必须可见，不再伪造 __missing__ 之外的静默）。
    private func ensureBaseline(_ xmpPath: String) async {
        let path = MetadataOutboxPath.normalize(xmpPath)
        let task: Task<Void, Never> = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = baselineTasks[path] { return existing }
            let task = Task { [weak self] in
                guard let self else { return }
                guard let row = try? self.outboxRepo.get(path), row.baseFingerprint.isEmpty else { return }
                let baselineFingerprint = (try? await MetadataFingerprint.contentFingerprint(path)) ?? ""
                var baselineValues = JSONValue.object([:])
                do {
                    baselineValues = try await self.xmp.readAttributes(photoPath: row.photoPath).asJSONValue
                } catch {
                    GatherLogger.log("Baseline read failed for \(path): \(error)", level: .warn)
                }
                do {
                    try self.outboxRepo.initializeBaseline(
                        xmpPath: path,
                        baselineFingerprint: baselineFingerprint.isEmpty ? "__missing__" : baselineFingerprint,
                        baselineValues: baselineValues)
                } catch {
                    GatherLogger.log("Baseline persist failed for \(path): \(error)", level: .error)
                }
            }
            baselineTasks[path] = task
            return task
        }()
        await task.value
        finishBaselineTaskLocked(path)
    }

    private func emitSummary(sessionId: String) throws -> MetadataSyncSummary {
        let summary = try getSummary(sessionId: sessionId)
        let sink = eventSinkLock.withLock { _eventSink }
        sink?(summary)
        return summary
    }

    /// 新写入活动使会话 reload-ack 失效（cleanup 的数据丢失门）。
    private func clearReloadAck(_ sessionId: String) throws {
        _ = try connection.prepare(
            "UPDATE sessions SET reload_acked_at = NULL, updated_at = ? WHERE id = ? AND reload_acked_at IS NOT NULL"
        ).run([.text(nowISOString()), .text(sessionId)])
    }

    private func clearReloadAckForXmpPath(_ xmpPath: String) {
        let sessionIds = (try? outboxRepo.getSessionIds(xmpPath)) ?? []
        for sessionId in sessionIds {
            do {
                try clearReloadAck(sessionId)
            } catch {
                GatherLogger.log("Failed to clear reload-ack for session \(sessionId): \(error)", level: .warn)
            }
        }
    }

    private func requireReloadAck(_ sessionId: String) throws {
        if skipReloadAck { return }
        let row = try connection.prepare("SELECT reload_acked_at FROM sessions WHERE id = ?")
            .get([.text(sessionId)])
        guard let acked = row?[0].textValue, !acked.isEmpty else {
            throw MetadataSyncError.reloadNotAcked
        }
    }

    /// 每行完成后的会话级合并推送（100ms 窗口 + 突发阈值）。
    private func emitPathSummaries(_ xmpPath: String) {
        let sessionIds = (try? outboxRepo.getSessionIds(xmpPath)) ?? []
        for sessionId in sessionIds {
            let decision = {
                lock.lock()
                defer { lock.unlock() }
                let count = (summaryEmitCounts[sessionId] ?? 0) + 1
                summaryEmitCounts[sessionId] = count
                summaryEmitTimers[sessionId]?.cancel()
                if count >= MetadataSyncCoordinator.summaryEmitBurstThreshold {
                    summaryEmitCounts[sessionId] = 0
                    return (burst: true, stoppedNow: stopped)
                }
                let task = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(MetadataSyncCoordinator.summaryEmitThrottleMs) * 1_000_000)
                    guard let self else { return }
                    if !self.consumeEmitTimer(sessionId) {
                        _ = try? self.emitSummary(sessionId: sessionId)
                    }
                }
                summaryEmitTimers[sessionId] = task
                return (burst: false, stoppedNow: stopped)
            }()
            if decision.burst, !decision.stoppedNow {
                _ = try? emitSummary(sessionId: sessionId)
            }
        }
    }

    private func consumeEmitTimer(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        summaryEmitTimers.removeValue(forKey: sessionId)
        summaryEmitCounts[sessionId] = 0
        return stopped
    }

    private func enqueueQueued(_ xmpPath: String) {
        let path = MetadataOutboxPath.normalize(xmpPath)
        lock.lock()
        defer { lock.unlock() }
        if queuedSet.insert(path).inserted {
            queued.append(path)
        }
    }

    private func cancelTimers(paths: [String]) {
        lock.lock()
        for path in paths {
            timers[path]?.cancel()
            timers.removeValue(forKey: path)
        }
        lock.unlock()
    }

    private func activeTask(for xmpPath: String) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return active[xmpPath]
    }

    private func snapshotTasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(baselineTasks.values) + Array(active.values)
    }

    // MARK: - 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）

    /// shutdown 的停止态临界区：置 stopped 并清空全部调度状态（锁内不含 await）。
    private func stopSchedulingLocked() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for timer in summaryEmitTimers.values { timer.cancel() }
        summaryEmitTimers.removeAll()
        summaryEmitCounts.removeAll()
        queued.removeAll()
        queuedSet.removeAll()
    }

    /// 基线单飞任务收尾：清除该路径的登记（锁内不含 await）。
    private func finishBaselineTaskLocked(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        baselineTasks.removeValue(forKey: path)
    }

    /// 备份文件清理（行已删除后的收尾）。失败只记日志：不产生悬空行，也不回滚已完成的删除。
    private func removeBackupBestEffort(_ backupPath: String) {
        guard !backupPath.isEmpty else { return }
        do {
            if FileManager.default.fileExists(atPath: backupPath) {
                try FileManager.default.removeItem(atPath: backupPath)
            }
        } catch {
            GatherLogger.log("Failed to remove metadata backup \(backupPath): \(error)", level: .warn)
        }
    }

    /// 接受远程值：把本地投影（缓存/挑片决策）对齐磁盘真实值。
    /// 这不是 XMP 写入路径（XMP 已由外部软件写成），只是投影刷新；失败必须可见。
    private func syncAcceptedRemoteValues(photoPath: String, remote: MetadataWriteAttributes) {
        do {
            if remote.isEmpty && xmp.fileExists(TSPath.xmpSidecarPath(photoPath)) {
                return
            }
            let photos = try connection.prepare("SELECT id, session_id FROM photos WHERE filepath = ?")
                .query([.text(ScanPath.canonical(photoPath))])
            let now = nowISOString()
            let keywords = remote.keywords ?? []
            let rating = clampRating(remote.rating)
            let label = sanitizeCullingLabel(remote.label)
            let keywordsJSON = try JSONValue.stringify(.array(keywords.map { .string($0) }))
            try connection.transaction {
                for photo in photos {
                    do {
                        _ = try connection.prepare("""
                            INSERT INTO photo_metadata_cache
                              (photo_id, session_id, keywords, rating, label, cached_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(photo_id) DO UPDATE SET
                              keywords = excluded.keywords,
                              rating = excluded.rating,
                              label = excluded.label,
                              cached_at = excluded.cached_at
                          """).run([
                            .text(photo[0].textValue ?? ""),
                            .text(photo[1].textValue ?? ""),
                            .text(keywordsJSON),
                            .int(Int64(rating)),
                            .text(label),
                            .text(now),
                          ])
                        _ = try connection.prepare("""
                            UPDATE culling_decisions
                            SET rating = ?, color_label = ?, updated_at = ?
                            WHERE photo_id = ? AND session_id = ?
                          """).run([
                            .int(Int64(rating)),
                            .text(label),
                            .text(now),
                            .text(photo[0].textValue ?? ""),
                            .text(photo[1].textValue ?? ""),
                          ])
                    } catch {
                        GatherLogger.log(
                            "Failed to sync accepted remote values for photo \(photo[0].textValue ?? ""): \(error)",
                            level: .warn)
                    }
                }
            }
        } catch {
            GatherLogger.log("Failed to sync accepted remote metadata values: \(error)", level: .warn)
        }
    }
}

/// TS: safeObject —— JSON 解析为对象；损坏/非对象返回 {}。
private func safeObject(_ value: String) -> JSONValue {
    guard let parsed = try? JSONValue.parse(value) else { return .object([:]) }
    if case .object = parsed { return parsed }
    return .object([:])
}

/// TS: attributesMatchPatch —— 当前属性是否恰好等于待写 patch（崩溃窗口判定）。
private func attributesMatchPatch(_ current: MetadataWriteAttributes, _ patch: JSONValue) -> Bool {
    if let rating = patch["rating"] {
        if rating == .null {
            if current.rating != nil { return false }
        } else if current.rating != rating.numberValue {
            return false
        }
    }
    if let label = patch["label"] {
        if label == .null { return false }
        if (current.label ?? "") != label.stringValue { return false }
    }
    if let keywords = patch["keywords"], case .array(let values) = keywords {
        let currentText = (try? JSONValue.stringify(.array(current.keywords?.map { .string($0) } ?? []))) ?? ""
        let patchText = (try? JSONValue.stringify(.array(values))) ?? ""
        if currentText != patchText { return false }
    }
    return true
}

/// TS: CULLING_COLOR_LABELS —— 唯一真相源是协议层枚举（与 metadata-contract 的
/// LABELS 同域，只是此处不接受空串：空/未知值一律归一为 "None"）。
private let cullingColorLabels: Set<String> = Set(CaptureOneColorLabel.allCases.map(\.rawValue))

/// TS: sanitizeCullingLabel。
private func sanitizeCullingLabel(_ value: String?) -> String {
    guard let value, cullingColorLabels.contains(value) else { return "None" }
    return value
}

/// TS: clampRating。
private func clampRating(_ value: Double?) -> Double {
    let num = value ?? 0
    return min(5, max(0, num.rounded()))
}

/// 写并发上限器。
private final class SlotGate: @unchecked Sendable {
    private let max: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(max: Int) { self.max = max }

    func acquire() async {
        if acquireSlotLocked() { return }
        await withCheckedContinuation { continuation in
            waitForSlotLocked(continuation)
        }
    }

    /// 立即取槽（true = 已取到，active 已 +1）。同步临界区辅助
    /// （Swift 6：async 上下文不得直接 lock/unlock）。
    private func acquireSlotLocked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < max else { return false }
        active += 1
        return true
    }

    /// 满员后挂起：复查并补取槽，否则登记等待者。resume 在锁外（与原实现一致）。
    private func waitForSlotLocked(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if active < max {
            active += 1
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    func release() {
        lock.lock()
        if active > 0 { active -= 1 }
        if let next = waiters.first {
            waiters.removeFirst()
            active += 1
            lock.unlock()
            next.resume()
        } else {
            lock.unlock()
        }
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active == 0 && waiters.isEmpty
    }
}
