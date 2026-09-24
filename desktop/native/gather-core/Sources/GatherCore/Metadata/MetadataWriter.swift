import Foundation

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

        public init(
            writebackStore: any WritebackStore,
            metadataStore: any MetadataStore,
            sessionStore: (any SessionStore)? = nil
        ) {
            self.writebackStore = writebackStore
            self.metadataStore = metadataStore
            self.sessionStore = sessionStore
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
