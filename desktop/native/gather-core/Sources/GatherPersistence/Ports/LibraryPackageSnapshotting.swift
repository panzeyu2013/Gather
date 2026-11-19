// desktop/native/gather-core/Sources/GatherPersistence/Ports/LibraryPackageSnapshotting.swift
// 目录包导出/导入的持久化快照端口（R1：维护/迁移路径端口化，2026-11-18 Wave 4）。
//
// 为什么单独切：原实现由 GatherApplication 的 LibraryPackageService 私有持有
// DBConnection，在方法内自建 SessionRepo / LibraryPackageStore / MetadataCacheRepo /
// CullingDecisionRepo 等 8 个仓储（架构评审 P1-1）。按"一次读齐 / 一次写齐"切粗粒度
// 快照端口，Application 只依赖本协议：包 JSON 编解码、版本校验、路径解析/文件 IO 留在
// Application，库访问与组织资产落库全部在 Persistence 内部实现。
//
// 事务边界与搬迁前一致：调用方负责事务（MaintenanceService 用 database.write 包导入），
// 端口实现不新开事务；直接调用（测试）时为逐语句自动提交。
//
// 方法数刻意控制在 3 个（导出快照 / 归档计数 / 导入），不把 8 个仓储的约 30 个方法摊到 Application。
import GatherProtocol

public protocol LibraryPackageSnapshotting: Sendable {
    /// 导出快照（只读）：会话 / 照片投影 / 集合成员 / 组织资产一次读齐。
    /// 会话不存在 → nil（调用方映射 SESSION_NOT_FOUND，与搬迁前逐字一致）。
    func exportSnapshot(sessionId: String, includeArchived: Bool) throws -> LibraryPackage?

    /// 归档计数（导出报告 skippedArchivedCount 用）。由既有
    /// LibraryPackageStore.archivedCount(sessionId:) 直接 witness，零新增实现。
    func archivedCount(sessionId: String) throws -> Int

    /// 导入（写）：建会话 / 照片行 / 元数据 / 决策 / 集合 / 组织资产，返回导入报告。
    /// - sessionName / effectiveRoot：由调用方解析（纯名称/路径规则，不触库）。
    /// - enqueueScan：metadata.scan 的注入接缝（nil = 走 AnalysisJobRepo 真实入队）。
    func importPackage(
        _ package: LibraryPackage,
        input: LibraryImportInput,
        sessionName: String,
        effectiveRoot: String,
        enqueueScan: (@Sendable (_ sessionId: String, _ requestedPaths: [String]) throws -> String)?
    ) throws -> LibraryImportReport
}
