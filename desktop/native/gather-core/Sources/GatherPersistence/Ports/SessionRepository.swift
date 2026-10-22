// desktop/native/gather-core/Sources/GatherPersistence/Ports/SessionRepository.swift
// WP3b-1：Session 仓储端口（只含 Application 实际调用的方法）。
//
// 具体实现仍是 SessionRepo；Application 只依赖本协议。默认参数在协议扩展里
// 补（协议要求本身不能带默认值），保证旧调用点的省略写法不变。
import Foundation

/// analysis_runs 只读投影（WorkspaceStatus 的过期判定）。
public struct AnalysisRunRecord: Equatable, Sendable {
    public let kind: String
    public let indexSeq: Int
    public let finishedAt: String

    public init(kind: String, indexSeq: Int, finishedAt: String) {
        self.kind = kind
        self.indexSeq = indexSeq
        self.finishedAt = finishedAt
    }
}

public protocol SessionRepository {
    func get(id: String) throws -> SessionRow?
    func create(name: String, source: String, sourcePath: String, truncatedImport: Bool) throws -> SessionRow
    func list() throws -> [SessionRow]
    func delete(id: String) throws -> Bool
    func deleteMany(ids: [String]) throws -> Int
    func deleteSimilarityDataBySession(sessionId: String) throws
    func updateName(id: String, name: String) throws -> Bool
    func updateStatus(id: String, status: String) throws
    func updatePhotoCount(id: String, count: Int) throws
    func getIndexSeq(id: String) throws -> Int
    func bumpIndexSeq(id: String) throws -> Int
    /// WorkspaceStatus：最近一次成功分析 run（status='ok'，ORDER BY id DESC）。
    func latestAnalysisRun(sessionId: String, kind: String) throws -> AnalysisRunRecord?
    /// SessionService：会话删除事务内的资产孤儿化（委托 AssetRepo）。
    func markOrphanedAssets() throws
}

public extension SessionRepository {
    func create(name: String, source: String) throws -> SessionRow {
        try create(name: name, source: source, sourcePath: "", truncatedImport: false)
    }
}

extension SessionRepo: SessionRepository {}
