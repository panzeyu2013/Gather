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

        public init(
            writebackStore: any WritebackStore,
            metadataStore: any MetadataStore,
            sessionStore: (any SessionStore)? = nil,
            xmpProvider: (any XMPProvider)? = nil
        ) {
            self.writebackStore = writebackStore
            self.metadataStore = metadataStore
            self.sessionStore = sessionStore
            self.xmpProvider = xmpProvider
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
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
