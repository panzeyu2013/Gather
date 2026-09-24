// API/Impl/IndexCommandsImpl.swift
// R5 命令层接线：index 域实现（批次 B3）。
// 逻辑来源：宿主路由层 index.scan 分支。旧分支建 metadata.scan 作业后立即返回
// 作业数据；本域按已冻结的协议契约（IndexCommands.swift 基线）直接落到
// IndexerRuntime.scan，返回 Protocol/Indexer.swift 的 IndexScanResult。
// confirmed 为可选且旧命令无破坏性门控，故实现不新增门控、不消费该字段。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// index 域命令实现：注入索引运行时（actor，串行化命令入口）。
public actor IndexCommandsImpl: IndexCommands {
    private let indexer: IndexerRuntime

    public init(indexer: IndexerRuntime) {
        self.indexer = indexer
    }

    /// 旧命令：`index.scan`。扫描已全量迁移至 IndexerRuntime（含缺失对账与
    /// index_seq 游标），命令边界只透传 sessionId 与 IndexScanParams。
    public func scan(_ params: IndexScanParams) async throws -> IndexScanResult {
        try await indexer.scan(sessionId: params.sessionId, options: params)
    }
}
