// desktop/native/gather-core/Sources/GatherPersistence/Ports/SimilarityHashRepository.swift
// WP3b-2：similarity_hashes 端口（Similarity / Duplicate / Indexer 共用的 hash 表）。
//
// Application 只表达「读哪些 hash、写哪些 hash」，SQL 与分块准备留在 Repo；
// 事务边界仍由调用方通过 TransactionRunner 提供（嵌套退化为 SAVEPOINT）。
import Foundation

public protocol SimilarityHashRepository {
    func getRecords(sessionId: String) throws -> [SimilarityHashRecord]
    func getHashMap(sessionId: String) throws -> [String: String]
    func upsert(_ rows: [SimilarityHashWrite]) throws
    func getPhotoAssetFileIds(sessionId: String) throws -> [PhotoAssetFileRef]
    func getReuseCandidates(assetFileIds: [String]) throws -> [SimilarityHashCandidate]
    func deleteByPhotoIds(_ photoIds: [String]) throws
}

extension SimilarityHashRepo: SimilarityHashRepository {}
