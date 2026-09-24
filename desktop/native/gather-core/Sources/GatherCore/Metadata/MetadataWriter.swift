import Foundation

/// TS: safeObject —— JSON 文本解析为对象，损坏或非对象一律退化为空对象
/// （与 Services/MetadataSyncCoordinator 的 safeObject 逐字同语义）。
private func metadataWriterSafeObject(_ value: String) -> JSONValue {
    guard let parsed = try? JSONValue.parse(value) else { return .object([:]) }
    if case .object = parsed { return parsed }
    return .object([:])
}

/// mwsum / W4-3a：getSummary —— 轻投影 + 分组计数（outboxCounts 为主、逐行过滤兜底），
/// 语义对齐 Services/MetadataSyncCoordinator.getSummary。
/// mwstate / W4-3b：getSessionState —— outbox 分组计数 + reload-ack 只读聚合。
/// W4-3d/W4-6：元数据提取 provider 集合（EXIF 解析 / 尺寸兜底 / 内嵌 XMP 读）。
/// nil = 宿主未接线：读路径遇未缓存 id 时显式标记 capability=unsupported，
/// 绝不静默返回空或不完整结果。W4-6 provider 一等注入时迁入 MetadataProviderContract.swift。
public struct MetadataProviderSet: Sendable {
    public let exif: (any ExifProvider)?
    public let dimensions: (any ImageDimensionsProvider)?
    public let embeddedReader: (any EmbeddedXMPReader)?

    public init(
        exif: (any ExifProvider)? = nil,
        dimensions: (any ImageDimensionsProvider)? = nil,
        embeddedReader: (any EmbeddedXMPReader)? = nil
    ) {
        self.exif = exif
        self.dimensions = dimensions
        self.embeddedReader = embeddedReader
    }

    /// 至少一条提取路径已接线；全 nil 等价于未接线（capability=unsupported）。
    public var isWired: Bool {
        exif != nil || dimensions != nil || embeddedReader != nil
    }
}

/// W4-3d：getMetadata 的显式能力标记错误。
/// providerSet 未接线时，未缓存 id 无法提取 —— 抛本错误并携带已命中缓存，
/// 绝不静默返回空字典或只含部分行的字典。
public enum MetadataWriterError: Error, Equatable, CustomStringConvertible {
    /// capability=unsupported：无任何提取 provider。
    case providerUnsupported(cached: [String: MetadataTags], missingPhotoIds: [String])
    /// provider 已接线，但提取所需的 photo 路径端口与批量 upsert 属写面
    /// （W4-4/W4-6）；读面不伪造提取结果，同样显式上抛。
    case extractionDeferred(cached: [String: MetadataTags], missingPhotoIds: [String])

    /// 已命中的缓存行（显式标记时一并带回，调用方不丢失可用数据）。
    public var cached: [String: MetadataTags] {
        switch self {
        case .providerUnsupported(let cached, _): cached
        case .extractionDeferred(let cached, _): cached
        }
    }

    /// 未命中的 photoId（保持请求顺序，含重复项，与旧实现一致）。
    public var missingPhotoIds: [String] {
        switch self {
        case .providerUnsupported(_, let missing): missing
        case .extractionDeferred(_, let missing): missing
        }
    }

    public var description: String {
        switch self {
        case .providerUnsupported: "METADATA_PROVIDER_UNSUPPORTED"
        case .extractionDeferred: "METADATA_EXTRACTION_DEFERRED"
        }
    }
}

public actor MetadataWriter {

    /// 注入依赖；协议组合可测（测试可传抛错替身）。
    public struct Dependencies: Sendable {
        public let writebackStore: any WritebackStore
        public let metadataStore: any MetadataStore
        /// 外部事实 E（sessions.reload_acked_at）只读端口：safeToCleanup 的唯一门。
        /// 缺省 nil = 未接线，getSessionState 按「未确认」保守处理。
        public let sessionStore: (any SessionStore)?
        /// sidecar 读取端口（getConflicts 每冲突行读一次）；缺省 nil = 未接线，
        /// 有冲突行时抛 conflictDetailsUnavailable，绝不伪造「无字段冲突」。
        public let xmpProvider: (any XMPProvider)?
        /// W4-3d：提取 provider 集合；缺省 nil = 无 provider。
        /// getMetadata 遇未缓存 id 时显式标记 capability=unsupported，绝不静默返回。
        public let providerSet: MetadataProviderSet?

        public init(
            writebackStore: any WritebackStore,
            metadataStore: any MetadataStore,
            sessionStore: (any SessionStore)? = nil,
            xmpProvider: (any XMPProvider)? = nil,
            providerSet: MetadataProviderSet? = nil
        ) {
            self.writebackStore = writebackStore
            self.metadataStore = metadataStore
            self.sessionStore = sessionStore
            self.xmpProvider = xmpProvider
            self.providerSet = providerSet
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - mww4 / W4-4 ① 写面去抖排程骨架

    /// 每个 xmpPath 一条排程条目：ticket 标识「最新一次 schedule」；
    /// generation 单调 +1（只增不减，测试用它断言合流次数）；
    /// 旧 ticket 的延迟任务醒来后发现 ticket 已被替换即自行退出。
    private struct ScheduleEntry: Sendable {
        var ticket: UUID
        var generation: UInt64
        var phase: Phase

        enum Phase: Sendable {
            case idle
            case debouncing
            case queued
            case inFlight
        }
    }

    private var entries: [String: ScheduleEntry] = [:]

    /// 默认去抖窗口（毫秒）：同路径高频写回在窗口内合并为一次。
    static let defaultDebounceDelayMs = 200

    /// 异步入队（非阻塞）：立即返回，实际登记在 actor 上串行执行。
    public nonisolated func schedule(xmpPath: String) {
        schedule(xmpPath: xmpPath, delayMs: nil)
    }

    /// delayMs = nil 用默认去抖窗口；0/负数表示不等待、下一跳立刻入队。
    public nonisolated func schedule(xmpPath: String, delayMs: Int?) {
        Task { await self.enqueue(xmpPath: xmpPath, delayMs: delayMs) }
    }

    /// generation 单调 +1；同路径重复调用只保留最新 ticket —— 旧 ticket 到点即弃。
    private func enqueue(xmpPath: String, delayMs: Int?) async {
        let generation = (entries[xmpPath]?.generation ?? 0) + 1
        let ticket = UUID()
        entries[xmpPath] = ScheduleEntry(
            ticket: ticket, generation: generation, phase: .debouncing)
        let delay = delayMs ?? Self.defaultDebounceDelayMs
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        guard entries[xmpPath]?.ticket == ticket else { return }
        entries[xmpPath]?.phase = .queued
    }

    /// 测试只读访问器（internal）：排程条目快照，按路径排序，不暴露私有类型。
    func scheduleSnapshot() -> [(xmpPath: String, generation: UInt64, phase: String)] {
        entries
            .map { ($0.key, $0.value.generation, String(describing: $0.value.phase)) }
            .sorted { $0.0 < $1.0 }
    }

    /// TS: getMetadata（W4-3d 读路径）—— 缓存轻投影 → 全命中返回 / 有未命中显式标记。
    /// 与 Services/MetadataService.getMetadata 的有意差异（留后续步骤）：
    /// ① 指纹失效检查需要 photo 文件路径端口（MetadataWriter 尚未接线，W4-6 补齐）；
    /// ② 未命中分支的 EXIF/sharp 提取与 upsertMetadataBatch 属写面（W4-4/W4-6），
    ///    本步只做读路径；未命中绝不静默吞掉，而是抛 MetadataWriterError 显式标记。
    public func getMetadata(photoIds: [String]) async throws -> [String: MetadataTags] {
        guard !photoIds.isEmpty else { return [:] }
        let cached = try await dependencies.metadataStore.metadataBatchLite(photoIds: photoIds)
        let missingPhotoIds = photoIds.filter { cached[$0] == nil }
        guard !missingPhotoIds.isEmpty else { return cached }
        if dependencies.providerSet?.isWired == true {
            throw MetadataWriterError.extractionDeferred(
                cached: cached, missingPhotoIds: missingPhotoIds)
        }
        throw MetadataWriterError.providerUnsupported(
            cached: cached, missingPhotoIds: missingPhotoIds)
    }

    /// TS: getSummary —— 轻投影 + 分组计数（countBySession 为主，逐行过滤兜底）。
    public func getSummary(sessionId: String) async throws -> MetadataSyncSummary {
        let rows = try await dependencies.writebackStore.outboxSummaries(sessionId: sessionId)
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
        let counts = try await dependencies.writebackStore.outboxCounts(sessionId: sessionId)
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

    /// TS: listOrphans —— 孤儿写回行全量投影（语义对齐 Services/MetadataSyncCoordinator.listOrphans：
    /// 读全部孤儿行，逐行映射为 MetadataOrphan；任何排序/过滤都交给 Store 查询）。
    public func listOrphans() async throws -> [MetadataOrphan] {
        try await dependencies.writebackStore.orphanOutbox().map { row in
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

    /// sidecar 读取的并发上限：与旧写入管线 MetadataSyncCoordinator.maxConcurrency 一致。
    /// 迁移期取本地常量，避免 Metadata/ 反向依赖 Services/。
    private static let sidecarReadConcurrency = 2

    /// TS: getConflicts —— 每个冲突行读一次磁盘上的 sidecar，并发与写入管线一致（上限 2）。
    /// 语义逐条对齐 Services/MetadataSyncCoordinator.getConflicts：
    /// 仅取 status == "conflict" 的行；base=baseValuesJSON、local=patchJSON、
    /// dirtyFields 损坏时按空列表处理；字段冲突由 MetadataConflictFields.fieldConflicts 判定。
    public func getConflicts(sessionId: String) async throws -> [MetadataConflict] {
        let rows = try await dependencies.writebackStore.outboxEntries(sessionId: sessionId)
            .filter { $0.status == "conflict" }
        // 空集无需 sidecar：保持与旧实现一致的 []，不因端口未接线而失败。
        guard !rows.isEmpty else { return [] }
        guard let xmp = dependencies.xmpProvider else {
            throw MetadataSyncError.conflictDetailsUnavailable
        }
        return try await ConcurrentMap.run(rows, concurrency: Self.sidecarReadConcurrency) { row in
            let current = try await xmp.readAttributes(photoPath: row.photoPath)
            let base = metadataWriterSafeObject(row.baseValuesJSON)
            let local = metadataWriterSafeObject(row.patchJSON)
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

    /// TS: getSessionState —— outbox 计数 + 宿主 reload-ack 的确定性聚合（纯函数 aggregateSessionState）。
    public func getSessionState(sessionId: String) async throws -> CaptureOneSessionState {
        let rawCounts = try await dependencies.writebackStore.outboxCounts(sessionId: sessionId)
        var counts: [String: Int] = [:]
        for (status, value) in rawCounts {
            counts[status] = Int(value)
        }
        // 缺省端口 = 无 ack 事实：保守按未确认处理，绝不凭猜测放行 safeToCleanup。
        let reloadAckedAt = try await dependencies.sessionStore?.reloadAckedAt(sessionId: sessionId)
        return aggregateSessionState(counts: counts, reloadAckedAt: reloadAckedAt)
    }
}
