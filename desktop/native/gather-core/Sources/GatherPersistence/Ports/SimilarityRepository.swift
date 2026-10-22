// desktop/native/gather-core/Sources/GatherPersistence/Ports/SimilarityRepository.swift
// WP3b-1：Similarity 仓储端口（结果行 + 增量簇状态）。
import Foundation

public protocol SimilarityRepository {
    func getLatest(sessionId: String) throws -> SimilarityResultRow?
    func getByThreshold(sessionId: String, threshold: Int) throws -> SimilarityResultRow?
    func replace(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64
    func replaceForThreshold(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64
    func getPhotoGroupMap(sessionId: String, resultId: Int64) throws -> [String: String]
    func getGroupMembers(sessionId: String, resultId: Int64) throws -> [SimilarityGroupMember]?
}

public protocol SimilarityClusterStateRepository {
    func load(sessionId: String) throws -> SimilarityClusterSnapshot?
    func apply(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        version: Int,
        incrementalUpdates: Int,
        memberCount: Int,
        algorithmVersion: Int,
        inputSignature: String,
        stateDigest: String,
        upserts: [SimilarityClusterStateWrite],
        removedPhotoIds: [String]
    ) throws
    func delete(sessionId: String) throws
}

extension SimilarityResultRepo: SimilarityRepository {}
extension SimilarityClusterStateRepo: SimilarityClusterStateRepository {}
