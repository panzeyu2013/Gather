import Foundation

/// mwsum / W4-3a：MetadataWriter actor —— 仅 getSummary 一个方法。
/// 轻投影 + 分组计数（outboxCounts 为主，逐行过滤兜底），语义对齐
/// Services/MetadataSyncCoordinator.getSummary。
public actor MetadataWriter {

    /// 注入依赖；协议组合可测（测试可传抛错替身）。
    public struct Dependencies: Sendable {
        public let writebackStore: any WritebackStore
        public let metadataStore: any MetadataStore

        public init(writebackStore: any WritebackStore, metadataStore: any MetadataStore) {
            self.writebackStore = writebackStore
            self.metadataStore = metadataStore
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
}
