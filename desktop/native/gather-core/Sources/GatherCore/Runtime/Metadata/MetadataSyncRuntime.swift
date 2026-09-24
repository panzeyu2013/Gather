// desktop/native/gather-core/Sources/GatherCore/Runtime/Metadata/MetadataSyncRuntime.swift
// R4：Services/MetadataSyncCoordinator.swift（982 行）→ Runtime 层 actor
// （公开类型/方法原样搬迁，Services 旧文件同批删除）。TS 源:
// desktop/src/main/services/metadata/metadata-sync-coordinator.ts（804 行，
// 状态机逐字段对齐）
//
// 协调状态机：outbox 行（metadata_outbox）是唯一持久真相源；本 Runtime 负责
// 去抖调度 → 基线快照 → 冲突检测 → 备份写回 → 自动重试（5 档退避）→ 摘要推送。
// 关键语义与 TS 逐字一致：
// - schedule() 先失效 reload-ack 再排程（cleanup 不得恢复 C1 从未加载过的备份）
// - processUntilCurrent 循环直至当前 revision 的 pending 被消费
// - 全局写并发上限 2（maxConcurrency），withSlot 排队
// - 崩溃窗口：备份存在 + 指纹与基线不符 + 当前内容恰为 patch → 补写 markWritten
// - 每次 schedule 即新写入活动 → clearReloadAckForXmpPath（数据丢失修复）
// - confirm/cleanup 主侧守卫 requireReloadAck（GATHER_TEST_SKIP_RELOAD_ACK →
//   skipReloadAck，测试注入）
//
// R4 分层归位（本层零 SQL、零锁原语、零非安全并发标注）：
// - reload-ack 清除/读取经 Store/SessionStore（clearReloadAckedAtForXmpPaths /
//   reloadAckedAt）；裁决接受远端值的 SQL 经 Store/WritebackStore
//   .applyAcceptedRemoteValues（W4-1 已下沉的 photos → photo_metadata_cache →
//   culling_decisions 单事务命令，连带清理 pending 投影与 outbox 行）。
// - 并发原语：actor 隔离取代 NSLock（原「async 上下文直接 lock()」告警消除）；
//   批并发统一 Runtime/Support/ConcurrentMap.run（取代本地 batchAsync 与锁游标
//   BatchCursor）；全局写槽位为 private actor SlotGate（continuation 唤醒）。
// - 等待语义不变：waitForIdle 仍按原 20ms 步进观察 writing 行，shutdown 仍等待
//   active/baseline 任务与槽位三空。
//
// 宿主路由层接线：MetadataSyncRuntime(writebackStore:xmp:sessionStore:...)，
// 摘要推送经 `await setEventSink { ... }`（actor 边界唯一写入入口）。

import Foundation

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
        case .orphanNotFound: "XMP_ORPHAN_NOT_FOUND"
        case .orphanNotRetryable: "XMP_ORPHAN_NOT_RETRYABLE"
        case .writerTimeout: "XMP_WRITER_TIMEOUT"
        }
    }
}

/// TS: WritebackService 依赖的协调器最小面（`Pick<MetadataSyncCoordinator,
/// 'waitForIdle' | 'flushSession' | 'confirmSync' | 'cleanup'>`）——
/// 3.4 CullingService / WritebackService 均只依赖该端口，测试可注入替身。
public protocol MetadataSyncPort: Sendable {
    func waitForIdle(xmpPath: String, timeoutMs: Int) async throws
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary
    func confirmSync(sessionId: String, sourceModule: String) async throws -> MetadataSyncSummary
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult
}

/// TS: MetadataSyncCoordinator —— Runtime 层 actor（R4 由 Services/ 迁入）。
/// actor 隔离取代原 NSLock + @unchecked 辅助类型：调度/基线/摘要计时器状态全部
/// 是 actor 私有（不跨边界），跨边界只经 async 方法。
public actor MetadataSyncRuntime: MetadataSyncPort {
    /// TS: MAX_CONCURRENCY。
    public static let maxConcurrency = 2
    /// TS: MAX_AUTOMATIC_ATTEMPTS。
    public static let maxAutomaticAttempts = 5
    /// TS: RETRY_DELAYS_MS。
    public static let retryDelaysMs: [Int] = [1_000, 2_000, 5_000, 15_000, 30_000]
    /// TS: SUMMARY_EMIT_THROTTLE_MS —— 后台逐行摘要推送的合并窗口。
    public static let summaryEmitThrottleMs = 100
    /// TS: SUMMARY_EMIT_BURST_THRESHOLD —— 窗口内完成行数达到该值立即推送。
    public static let summaryEmitBurstThreshold = 50

    /// TS: settings.getNumber('metadata_write_debounce_ms', 500)。
    public static let defaultWriteDebounceMs = 500
    /// TS: waitForIdle 的默认超时（5000ms）。
    public static let defaultWaitTimeoutMs = 5_000

    private let writebackStore: any WritebackStore
    private let xmp: any XMPProvider
    private let sessionStore: any SessionStore
    private let getNumber: (String, Double) -> Double
    /// TS: process.env.GATHER_TEST_SKIP_RELOAD_ACK === '1'（e2e/单测跳过 reload-ack 守卫）。
    public let skipReloadAck: Bool

    /// TS: eventSink（summary push 回调，宿主组合根接线）。
    /// actor 隔离：只在 actor 内读；跨边界写入只有 setEventSink（无锁、无拷贝态）。
    /// 宿主组合根需要在构造后注入 summary 推送回调（路由装配点直接赋值）；
    /// 亦可经 start(eventSink:) 注入（该 API 会同时启动循环）。
    nonisolated(unsafe) public var eventSink: (@Sendable (MetadataSyncSummary) -> Void)?

    /// TS: timers（Map<xmpPath, Timeout>）→ 可取消 Task。
    private var timers: [String: Task<Void, Never>] = [:]
    /// TS: queued（Set，插入序）—— drain 顺序即排队顺序。
    private var queued: [String] = []
    private var queuedSet: Set<String> = []
    /// TS: active（Map<xmpPath, Promise>）。
    private var active: [String: Task<Void, Never>] = [:]
    /// TS: baselineTasks（Map<xmpPath, Promise>，单飞去重）。
    private var baselineTasks: [String: Task<Void, Never>] = [:]
    /// TS: summaryEmitTimers / summaryEmitCounts（会话级合并推送）。
    private var summaryEmitTimers: [String: Task<Void, Never>] = [:]
    private var summaryEmitCounts: [String: Int] = [:]
    private var stopped = false

    /// TS: activeCount + slotWaiters 的等价物（全局写并发上限）。
    private let slotGate = SlotGate(max: MetadataSyncRuntime.maxConcurrency)

    public init(
        writebackStore: any WritebackStore,
        xmp: any XMPProvider,
        sessionStore: any SessionStore,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        skipReloadAck: Bool = false
    ) {
        self.writebackStore = writebackStore
        self.xmp = xmp
        self.sessionStore = sessionStore
        self.getNumber = getNumber
        self.skipReloadAck = skipReloadAck
    }

    /// 摘要推送接线（宿主组合根）：跨 actor 边界只有本方法。
    public func setEventSink(_ sink: (@Sendable (MetadataSyncSummary) -> Void)?) {
        eventSink = sink
    }

    // MARK: - 公开 API（与 TS 方法一一对应）

    /// TS: start —— 恢复被中断的行并重新排程 recoverable active 行。
    public func start(eventSink: (@Sendable (MetadataSyncSummary) -> Void)? = nil) async {
        stopped = false
        setEventSink(eventSink)
        // Orphan（创建会话已删除的行）有意保留：它们是可通过全局恢复 UI 找回的
        // XMP 工作，不是垃圾；但绝不在此自动重试（已删会话的 pending 工作不得
        // 在后台无 UI 记录地写 XMP）。Orphan 只能经 resolveOrphan('retry') 显式重试。
        _ = try? await writebackStore.recoverInterruptedOutbox()
        for row in (try? await writebackStore.recoverableActiveOutbox()) ?? [] {
            schedule(xmpPath: row.xmpPath, delayMs: 0)
        }
    }

    /// TS: schedule —— 排程一次写入；取消旧计时器并失效 reload-ack。
    /// nonisolated：宿主路由层与变更 Runtime 在同步上下文调用，实际登记交给 actor。
    public nonisolated func schedule(xmpPath: String, delayMs: Int? = nil) {
        Task { await self.enqueueSchedule(xmpPath: xmpPath, delayMs: delayMs) }
    }

    /// TS: getSummary —— 轻投影 + 分组计数（countBySession 为主，逐行过滤兜底）。
    public func getSummary(sessionId: String) async throws -> MetadataSyncSummary {
        let rows = try await writebackStore.outboxSummaries(sessionId: sessionId)
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
        let counts = try await writebackStore.outboxCounts(sessionId: sessionId)
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

    /// TS: getConflicts —— 每个冲突行读一次磁盘上的 sidecar，并发与写入管线一致。
    public func getConflicts(sessionId: String) async throws -> [MetadataConflict] {
        let rows = try await writebackStore.outboxEntries(sessionId: sessionId).filter { $0.status == "conflict" }
        let provider = xmp
        return try await ConcurrentMap.run(rows, concurrency: MetadataSyncRuntime.maxConcurrency) { row in
            let current = try await provider.readAttributes(photoPath: row.photoPath)
            let base = safeObject(row.baseValuesJSON)
            let local = safeObject(row.patchJSON)
            let dirtyFields = MetadataConflictFields.parseDirtyFields(row.dirtyFields)
            let fields = MetadataConflictFields.fieldConflicts(
                base: base, local: local, current: current, dirtyFields: dirtyFields
            )
            return MetadataConflict(
                xmpPath: row.xmpPath,
                photoPath: row.photoPath,
                revision: Int(row.revision),
                fields: fields
            )
        }
    }

    /// TS: resolveConflict —— 逐字段裁决；全 use_remote 时删除行并同步缓存/决策表。
    public func resolveConflict(
        sessionId: String,
        xmpPath: String,
        choices: [MetadataField: MetadataConflictChoice]
    ) async throws -> MetadataSyncSummary {
        let row = try await writebackStore.outboxEntries(sessionId: sessionId).first { $0.xmpPath == xmpPath }
        guard let row, row.status == "conflict" else { throw MetadataSyncError.conflictNotFound }
        let conflict = try await getConflicts(sessionId: sessionId).first { $0.xmpPath == xmpPath }
        guard let conflict, !conflict.fields.isEmpty else { throw MetadataSyncError.conflictDetailsUnavailable }
        for field in conflict.fields where choices[field.field] == nil {
            GatherLogger.log("Missing conflict choice for field \(field.field.rawValue)", level: .warn)
            throw MetadataSyncError.choiceMissing
        }
        let current = try await xmp.readAttributes(photoPath: row.photoPath)
        var patch = safeObject(row.patchJSON)
        guard var dirtyFields = MetadataConflictFields.tryParseDirtyFields(row.dirtyFields) else {
            throw MetadataSyncError.conflictDetailsInvalid
        }
        for (field, choice) in choices where choice == .useRemote {
            if case .object(var dict) = patch {
                dict.removeValue(forKey: field.rawValue)
                patch = .object(dict)
            }
            dirtyFields.removeAll { $0 == field }
        }
        let acceptRemote = dirtyFields.isEmpty
        if acceptRemote {
            // 保持原 syncAcceptedRemoteValues 的语义：损坏的 sidecar 让
            // readAttributes 返回空对象时，空读取不得清空先前有效缓存值
            // （镜像 metadata.service 守卫）；其余情况把钳制/归一后的外部值交给
            // Store 单事务命令（W4-1 下沉：photos → 缓存 upsert → 决策更新，
            // 并连带清理 pending 投影与 outbox 行）。
            if current.isEmpty && xmp.fileExists(TSPath.xmpSidecarPath(row.photoPath)) {
                _ = try await writebackStore.discardWritebackPending(xmpPath: xmpPath)
            } else {
                _ = try await writebackStore.applyAcceptedRemoteValues(
                    sessionId: sessionId,
                    xmpPath: xmpPath,
                    rating: Int(clampRating(current.rating)),
                    label: sanitizeCullingLabel(current.label),
                    keywords: current.keywords ?? []
                )
            }
        }
        let fingerprint = try await MetadataFingerprint.contentFingerprint(xmpPath)
        try await writebackStore.resolveOutboxConflict(
            xmpPath: xmpPath,
            patch: patch,
            dirtyFields: dirtyFields.map(\.rawValue),
            baselineFingerprint: fingerprint.isEmpty ? "__missing__" : fingerprint,
            baselineValues: current.asJSONValue,
            acceptRemote: acceptRemote
        )
        if !acceptRemote { schedule(xmpPath: xmpPath, delayMs: 0) }
        return try await emitSummary(sessionId: sessionId)
    }

    /// TS: listOrphans。
    public func listOrphans() async throws -> [MetadataOrphan] {
        try await writebackStore.orphanOutbox().map { row in
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
        let row = try await writebackStore.orphanOutbox().first { $0.xmpPath == xmpPath }
        guard let row else { throw MetadataSyncError.orphanNotFound }
        if action == .retry {
            if row.status == "conflict" { throw MetadataSyncError.conflictResolutionRequired }
            if row.status == "failed" {
                try await writebackStore.resetOutboxForRetry(xmpPath: xmpPath)
            } else if row.status != "pending" {
                throw MetadataSyncError.orphanNotRetryable
            }
            schedule(xmpPath: xmpPath, delayMs: 0)
            return try await listOrphans()
        }
        try await waitForIdle(xmpPath: xmpPath, timeoutMs: MetadataSyncRuntime.defaultWaitTimeoutMs)
        if action == .restore {
            if !row.backupPath.isEmpty {
                if !xmp.fileExists(row.backupPath) {
                    GatherLogger.log("XMP backup is missing for orphan restore: \(row.backupPath)", level: .warn)
                    throw MetadataSyncError.backupMissing
                }
                try await xmp.restore(photoPath: row.photoPath, backupPath: row.backupPath)
            } else if xmp.fileExists(row.xmpPath) {
                try await xmp.removeFile(row.xmpPath)
            }
        } else if !row.backupPath.isEmpty && xmp.fileExists(row.backupPath) {
            try await xmp.removeFile(row.backupPath)
        }
        try await writebackStore.deleteOutbox(xmpPath: xmpPath)
        return try await listOrphans()
    }

    /// TS: flushSession —— 取消会话内全部计时器后并行跑 pending/writing/failed 行。
    public func flushSession(sessionId: String) async throws -> MetadataSyncSummary {
        let paths = try await writebackStore.outboxEntries(sessionId: sessionId)
            .filter { ["pending", "writing", "failed"].contains($0.status) }
            .map(\.xmpPath)
        cancelTimers(paths: paths)
        // 同步登记 active（对齐 TS `Promise.all(paths.map(runPath))` 的先登记语义）。
        let tasks = paths.map { runPath($0) }
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask { await task.value }
            }
            await group.waitForAll()
        }
        return try await getSummary(sessionId: sessionId)
    }

    /// TS: retrySession —— failed 行重置后整体 flush。
    public func retrySession(sessionId: String) async throws -> MetadataSyncSummary {
        for row in try await writebackStore.outboxEntries(sessionId: sessionId) where row.status == "failed" {
            try await writebackStore.resetOutboxForRetry(xmpPath: row.xmpPath)
            await clearReloadAckForXmpPath(row.xmpPath)
        }
        return try await flushSession(sessionId: sessionId)
    }

    /// TS: confirmSync —— 主侧守卫（reload-ack）通过后整会话置 synced。
    public func confirmSync(sessionId: String, sourceModule: String) async throws -> MetadataSyncSummary {
        let summary = try await getSummary(sessionId: sessionId)
        if summary.pending > 0 || summary.writing > 0 || summary.failed > 0 || summary.conflict > 0 {
            throw MetadataSyncError.confirmIncomplete
        }
        // 主侧守卫（闭合渲染层陈旧视图竞态）：确认同步把行提升到 synced
        // （解锁 cleanup），因此 C1 必须已加载元数据——即必须存在 reload ack。
        // 缺失时 cleanup 可能恢复 C1 从未加载过的 XMP 备份。
        try await requireReloadAck(sessionId)
        try await writebackStore.markSessionSynced(sessionId: sessionId, sourceModule: sourceModule)
        return try await emitSummary(sessionId: sessionId)
    }

    /// TS: cleanup —— 只恢复本模块写入的行（另一模块未确认的 XMP 不得被恢复）。
    public func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
        let rows = try await writebackStore.outboxEntries(sessionId: sessionId)
        let eligible = rows.filter { $0.status == "synced" && $0.sourceModule == sourceModule }
        if eligible.isEmpty && !rows.isEmpty {
            throw MetadataSyncError.cleanupRequiresLoaded
        }
        // cleanup 会恢复备份，同样受 reload-ack 门控；无可恢复行时不要求 ack。
        if !eligible.isEmpty { try await requireReloadAck(sessionId) }
        // 每行序列（waitForIdle → 指纹复核 → 恢复/删除 → 标记 cleaned）只在本行
        // 内有顺序敏感性，无关行可并行。
        let store = writebackStore
        let provider = xmp
        let results = try await ConcurrentMap.run(
            eligible, concurrency: MetadataSyncRuntime.maxConcurrency
        ) { row -> (deleted: Bool, error: String?) in
            do {
                // 快照后可能排入新变更：恢复/删除文件前等待在飞写入并复核行仍 synced，
                // 以免并发编辑被静默还原。
                try await self.waitForIdle(xmpPath: row.xmpPath, timeoutMs: MetadataSyncRuntime.defaultWaitTimeoutMs)
                guard let latest = try await store.outboxEntry(xmpPath: row.xmpPath), latest.status == "synced" else { return (false, nil) }
                let currentFingerprint = try await MetadataFingerprint.contentFingerprint(row.xmpPath)
                if !latest.baseFingerprint.isEmpty && currentFingerprint != latest.baseFingerprint {
                    try await store.markOutboxStatus(xmpPath: row.xmpPath, status: "conflict", errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT")
                    throw MetadataSyncError.externallyModified
                }
                if !latest.backupPath.isEmpty {
                    guard provider.fileExists(latest.backupPath) else { throw MetadataSyncError.backupMissing }
                    try await provider.restore(photoPath: latest.photoPath, backupPath: latest.backupPath)
                } else if provider.fileExists(latest.xmpPath) {
                    try await provider.removeFile(latest.xmpPath)
                }
                try await store.markOutboxStatus(xmpPath: latest.xmpPath, status: "cleaned")
                try await store.deleteOutbox(xmpPath: latest.xmpPath)
                return (true, nil)
            } catch {
                return (false, "\(row.xmpPath): \(String(describing: error))")
            }
        }
        var deletedCount = 0
        var errors: [String] = []
        for result in results {
            if result.deleted { deletedCount += 1 }
            else if let error = result.error { errors.append(error) }
        }
        _ = try? await emitSummary(sessionId: sessionId)
        return CleanupResult(deletedCount: deletedCount, errors: errors)
    }

    /// TS: finalizeSession —— 删除恢复备份并 revision 守卫地删除行。
    public func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary {
        let rows = try await writebackStore.outboxEntries(sessionId: sessionId)
        let eligible = rows.filter { $0.status == "synced" }
        if eligible.isEmpty && !rows.isEmpty {
            throw MetadataSyncError.confirmRequiresSync
        }
        // 行内顺序敏感（先删备份后删行：unlink 失败必须保留行以便重试，
        // 避免 .gather-backup 永久泄漏）；无关行可并行。
        let store = writebackStore
        let provider = xmp
        _ = try await ConcurrentMap.run(eligible, concurrency: MetadataSyncRuntime.maxConcurrency) { row in
            try await self.waitForIdle(xmpPath: row.xmpPath, timeoutMs: MetadataSyncRuntime.defaultWaitTimeoutMs)
            guard let latest = try await store.outboxEntry(xmpPath: row.xmpPath), latest.status == "synced" else { return }
            let backupPath = latest.backupPath
            if !backupPath.isEmpty && provider.fileExists(backupPath) {
                try await provider.removeFile(backupPath)
            }
            // revision 守卫删除：备份移除期间排入的变更会 bump revision，
            // 只删恰被 finalize 的行，新事务存活。
            try await store.deleteOutboxByRevision(xmpPath: latest.xmpPath, revision: latest.revision)
            // 存活的同路径行不得继续指向已删除的备份（后续写入会跳过新建备份、
            // cleanup 会因悬空路径失败），陈旧引用清除。
            if !backupPath.isEmpty {
                try await store.clearOutboxBackupPath(xmpPath: latest.xmpPath, backupPath: backupPath)
            }
        }
        return try await emitSummary(sessionId: sessionId)
    }

    /// TS: shutdown —— 停排程、取消计时器、等待全部在飞任务与槽位等待者排空。
    public func shutdown() async {
        stopped = true
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for timer in summaryEmitTimers.values { timer.cancel() }
        summaryEmitTimers.removeAll()
        summaryEmitCounts.removeAll()
        queued.removeAll()
        queuedSet.removeAll()
        // 快照后仍可能新增任务（槽位等待者被唤醒后启动自己的任务；并发
        // flushSession 可直接调用 runPath）——循环等待直至 active 为空
        // 且无 parked 等待者，保证 shutdown 返回后没有任务再碰数据库。
        while true {
            let tasks = snapshotTasks()
            let slotIdle = await slotGate.isIdle
            if tasks.isEmpty && slotIdle { break }
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
                await group.waitForAll()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// TS: waitForIdle(xmpPath, timeoutMs = 5000) —— 等待该路径在飞写入结束。
    public func waitForIdle(xmpPath: String, timeoutMs: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let activeTask = activeTask(for: xmpPath) {
                await activeTask.value
            }
            guard let row = try? await writebackStore.outboxEntry(xmpPath: xmpPath), row.status == "writing" else { return }
            if Date() >= deadline {
                GatherLogger.log("Timed out waiting for metadata writer: \(xmpPath)", level: .warn)
                throw MetadataSyncError.writerTimeout
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 内部（与 TS 私有方法一一对应）

    /// TS: schedule 的 actor 内登记段（去抖计时器 + 基线快照 + 摘要前置）。
    private func enqueueSchedule(xmpPath: String, delayMs: Int?) async {
        guard !stopped else { return }
        // 每次 schedule() 都是新写入活动（行刚插入或转入 pending/writing/failed）：
        // 会话上一次 reload ack 不再覆盖该文件。在行可能变为 written/synced 之前
        // 失效之，使渲染门控与 confirm/cleanup 守卫永远看不到陈旧 ack
        // （数据丢失修复：cleanup 不得恢复 C1 从未加载过的备份）。
        await clearReloadAckForXmpPath(xmpPath)
        // TS: void this.ensureBaseline(xmpPath) —— 基线快照立即（去抖窗口前）启动。
        await ensureBaseline(xmpPath)
        let delay = delayMs ?? max(0, Int(getNumber("metadata_write_debounce_ms", Double(MetadataSyncRuntime.defaultWriteDebounceMs))))
        timers[xmpPath]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard let self else { return }
            await self.ensureBaseline(xmpPath)
            await self.enqueueQueued(xmpPath)
            await self.drain()
        }
        timers[xmpPath] = task
    }

    private func drain() {
        while true {
            guard !stopped, !queued.isEmpty else { return }
            let nextPath = queued.removeFirst()
            queuedSet.remove(nextPath)
            _ = runPath(nextPath)
        }
    }

    @discardableResult
    private func runPath(_ xmpPath: String) -> Task<Void, Never> {
        guard !stopped else { return Task {} }
        if let existing = active[xmpPath] { return existing }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.withSlot {
                await self.processUntilCurrent(xmpPath)
            }
            await self.finishRun(xmpPath)
        }
        active[xmpPath] = task
        return task
    }

    /// TS: runPath 的 .finally 段（从 active 摘除并继续 drain）。
    private func finishRun(_ xmpPath: String) {
        active.removeValue(forKey: xmpPath)
        drain()
    }

    private func withSlot(_ operation: () async -> Void) async {
        await slotGate.acquire()
        await operation()
        await slotGate.release()
    }

    /// TS: processUntilCurrent —— 循环处理直至当前 revision 消费完毕。
    private func processUntilCurrent(_ xmpPath: String) async {
        while true {
            if stopped { return }
            await ensureBaseline(xmpPath)
            guard let row = try? await writebackStore.outboxEntry(xmpPath: xmpPath),
                  ["pending", "writing", "failed"].contains(row.status) else { return }
            let shouldContinue = await processRow(row)
            if !shouldContinue { return }
            guard let latest = try? await writebackStore.outboxEntry(xmpPath: xmpPath), latest.status == "pending" else { return }
        }
    }

    /// TS: processRow —— 单行处理：claim → 崩溃窗口补写/冲突检测 → 备份写回 → markWritten。
    private func processRow(_ row: OutboxRecord) async -> Bool {
        guard (try? await writebackStore.claimOutbox(xmpPath: row.xmpPath, expectedRevision: row.revision)) ?? false else { return false }
        // 行现在处于 writing：队列与 claim 之间幸存的任何 reload-ack
        // （崩溃窗口）都必须在行可达 written 前失效。
        await clearReloadAckForXmpPath(row.xmpPath)

        do {
            let currentFingerprint = try await MetadataFingerprint.contentFingerprint(row.xmpPath)
            let currentToken = currentFingerprint.isEmpty ? "__missing__" : currentFingerprint
            // 原子 rename 与 markWritten 之间的崩溃会把文件留在"已含本次写入"状态，
            // 而基线仍描述原始内容。检测该情况并补完事务，而不是误报外部冲突。
            if !row.backupPath.isEmpty, !row.baseFingerprint.isEmpty, currentToken != row.baseFingerprint {
                let current = try await xmp.readAttributes(photoPath: row.photoPath)
                if attributesMatchPatch(current, safeObject(row.patchJSON)) {
                    try await writebackStore.markOutboxWritten(
                        xmpPath: row.xmpPath,
                        revision: row.revision,
                        fingerprint: currentToken,
                        baseValues: current.asJSONValue,
                        backupPath: row.backupPath
                    )
                    await emitPathSummaries(row.xmpPath)
                    return true
                }
            }
            if !row.baseFingerprint.isEmpty, currentToken != row.baseFingerprint, try await hasDirtyFieldConflict(row) {
                try await writebackStore.markOutboxStatus(xmpPath: row.xmpPath, status: "conflict", errorMessage: "XMP_EXTERNAL_EDIT_CONFLICT")
                await emitPathSummaries(row.xmpPath)
                return false
            }

            let backupPath: String
            if !row.backupPath.isEmpty {
                backupPath = row.backupPath
            } else {
                backupPath = try await xmp.backup(photoPath: row.photoPath)
                try await writebackStore.setOutboxBackupPath(xmpPath: row.xmpPath, backupPath: backupPath)
            }
            let patch = safeObject(row.patchJSON)
            try await xmp.writeAttributes(photoPath: row.photoPath, attributes: MetadataWriteAttributes(
                keywords: patch["keywords"]?.arrayElements?.compactMap { $0.stringValue },
                rating: patch["rating"]?.numberValue,
                label: patch["label"]?.stringValue
            ))
            let persistedValues = try await xmp.readAttributes(photoPath: row.photoPath)
            let writtenFingerprint = try await MetadataFingerprint.contentFingerprint(row.xmpPath)
            try await writebackStore.markOutboxWritten(
                xmpPath: row.xmpPath,
                revision: row.revision,
                fingerprint: writtenFingerprint,
                baseValues: persistedValues.asJSONValue,
                backupPath: backupPath
            )
            await emitPathSummaries(row.xmpPath)
            return true
        } catch {
            let message = String(describing: error)
            try? await writebackStore.markOutboxStatus(xmpPath: row.xmpPath, status: "failed", errorMessage: message)
            let latest = try? await writebackStore.outboxEntry(xmpPath: row.xmpPath)
            if let latest, latest.attemptCount < MetadataSyncRuntime.maxAutomaticAttempts {
                let retryIndex = min(Int(latest.attemptCount) - 1, MetadataSyncRuntime.retryDelaysMs.count - 1)
                schedule(xmpPath: row.xmpPath, delayMs: MetadataSyncRuntime.retryDelaysMs[max(0, retryIndex)])
            }
            await emitPathSummaries(row.xmpPath)
            return false
        }
    }

    /// TS: hasDirtyFieldConflict。
    private func hasDirtyFieldConflict(_ row: OutboxRecord) async throws -> Bool {
        let current = try await xmp.readAttributes(photoPath: row.photoPath)
        let base = safeObject(row.baseValuesJSON)
        let dirtyFields = MetadataConflictFields.tryParseDirtyFields(row.dirtyFields)
        // 损坏的 stored dirty-fields 保守地视为冲突；合法空列表 = 无冲突。
        guard let dirtyFields else { return true }
        return MetadataConflictFields.hasFieldConflict(base: base, current: current, dirtyFields: dirtyFields)
    }

    /// TS: ensureBaseline —— 单飞；行无基线时快照内容指纹与属性基线。
    private func ensureBaseline(_ xmpPath: String) async {
        let task: Task<Void, Never>
        if let existing = baselineTasks[xmpPath] {
            task = existing
        } else {
            let created = Task { [weak self] in
                guard let self else { return }
                guard let row = try? await self.writebackStore.outboxEntry(xmpPath: xmpPath), row.baseFingerprint.isEmpty else { return }
                let baselineFingerprint = (try? await MetadataFingerprint.contentFingerprint(row.xmpPath)) ?? ""
                var baselineValues = JSONValue.object([:])
                do {
                    baselineValues = (try await self.xmp.readAttributes(photoPath: row.photoPath)).asJSONValue
                } catch {
                    // 损坏的 sidecar 在此被指纹化并由 writer 拒绝。
                }
                try? await self.writebackStore.initializeOutboxBaseline(
                    xmpPath: xmpPath,
                    baselineFingerprint: baselineFingerprint.isEmpty ? "__missing__" : baselineFingerprint,
                    baselineValues: baselineValues
                )
            }
            baselineTasks[xmpPath] = created
            task = created
        }
        await task.value
        baselineTasks.removeValue(forKey: xmpPath)
    }

    private func emitSummary(sessionId: String) async throws -> MetadataSyncSummary {
        let summary = try await getSummary(sessionId: sessionId)
        eventSink?(summary)
        return summary
    }

    /// TS: clearReloadAck —— 新写入活动使会话 reload-ack 失效（耐久半部的
    /// safeToCleanup 门，数据丢失修复）。Store/SessionStore 单事务命令（W4-1c）。
    private func clearReloadAckForXmpPath(_ xmpPath: String) async {
        _ = try? await sessionStore.clearReloadAckedAtForXmpPaths([xmpPath])
    }

    /// TS: requireReloadAck —— 主侧守卫；GATHER_TEST_SKIP_RELOAD_ACK 等价跳过。
    private func requireReloadAck(_ sessionId: String) async throws {
        if skipReloadAck { return }
        guard let acked = try await sessionStore.reloadAckedAt(sessionId: sessionId), !acked.isEmpty else {
            throw MetadataSyncError.reloadNotAcked
        }
    }

    /// TS: emitPathSummaries —— 每行完成后的会话级合并推送（100ms 窗口 + 突发阈值）。
    private func emitPathSummaries(_ xmpPath: String) async {
        let sessionIds = (try? await writebackStore.outboxSessionIds(xmpPath: xmpPath)) ?? []
        for sessionId in sessionIds {
            let count = (summaryEmitCounts[sessionId] ?? 0) + 1
            summaryEmitCounts[sessionId] = count
            summaryEmitTimers[sessionId]?.cancel()
            if count >= MetadataSyncRuntime.summaryEmitBurstThreshold {
                summaryEmitCounts[sessionId] = 0
                if !stopped {
                    _ = try? await emitSummary(sessionId: sessionId)
                }
                continue
            }
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(MetadataSyncRuntime.summaryEmitThrottleMs) * 1_000_000)
                guard let self else { return }
                if !(await self.consumeEmitTimer(sessionId)) {
                    _ = try? await self.emitSummary(sessionId: sessionId)
                }
            }
            summaryEmitTimers[sessionId] = task
        }
    }

    /// 摘除已触发的合并推送计时器并返回是否已停止。
    private func consumeEmitTimer(_ sessionId: String) -> Bool {
        summaryEmitTimers.removeValue(forKey: sessionId)
        summaryEmitCounts[sessionId] = 0
        return stopped
    }

    private func enqueueQueued(_ xmpPath: String) {
        if queuedSet.insert(xmpPath).inserted {
            queued.append(xmpPath)
        }
    }

    private func cancelTimers(paths: [String]) {
        for path in paths {
            timers[path]?.cancel()
            timers.removeValue(forKey: path)
        }
    }

    private func activeTask(for xmpPath: String) -> Task<Void, Never>? {
        active[xmpPath]
    }

    private func snapshotTasks() -> [Task<Void, Never>] {
        Array(baselineTasks.values) + Array(active.values)
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

/// TS: CULLING_COLOR_LABELS。
private let cullingColorLabels: Set<String> = [
    "None", "Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple",
]

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

/// TS: withSlot 的并发上限器（activeCount + slotWaiters 等价物）。
/// actor 隔离取代原 NSLock 与锁游标标注；等待经 continuation 唤醒。
private actor SlotGate {
    private let max: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(max: Int) { self.max = max }

    func acquire() async {
        if active < max {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if active > 0 { active -= 1 }
        if let next = waiters.first {
            waiters.removeFirst()
            active += 1
            next.resume()
        }
    }

    var isIdle: Bool { active == 0 && waiters.isEmpty }
}
