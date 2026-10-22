// desktop/native/gather-core/Sources/GatherPersistence/Ports/PersonRepository.swift
// WP3b-1：Person 仓储端口（只含 Application 实际调用的方法）。
import Foundation

public protocol PersonRepository {
    func summaries(ids: [String]) throws -> [String: PersonIdentitySummary]
    func get(id: String) throws -> PersonRow?
    func upsertByName(name: String, keywords: [String]?) throws -> String
    func bindRole(
        clusterId: Int64,
        sessionId: String,
        roleName: String,
        keywords: [String],
        members: [PersonPhotoInput]
    ) throws -> PersonIdentityOutcome
    func reconcileSession(sessionId: String) throws
    func saveEmbeddings(embeddings: [SaveEmbeddingInput]) throws
    func getAllEmbeddings(modelSpace: String?) throws -> [PersonEmbeddingRef]
    /// SessionService：删除会话前清理 person 侧行。
    func deleteSessionRows(sessionId: String) throws
}

public extension PersonRepository {
    func upsertByName(name: String) throws -> String {
        try upsertByName(name: name, keywords: nil)
    }

    func getAllEmbeddings() throws -> [PersonEmbeddingRef] {
        try getAllEmbeddings(modelSpace: nil)
    }
}

extension PersonRepo: PersonRepository {}
