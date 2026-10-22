// desktop/native/gather-core/Sources/GatherPersistence/Ports/FaceRepository.swift
// WP3b-1：Face 仓储端口（只含 Application 实际调用的方法）。
import Foundation

public protocol FaceRepository {
    func getObservations(_ sessionId: String) throws -> [FaceObservationRow]
    func countsByPhoto(sessionId: String, photoIds: [String]) throws -> [String: Int]
    func getAnalysisStates(_ sessionId: String) throws -> [String: FaceAnalysisState]
    func reuseObservationsForAssetFile(
        sessionId: String,
        targets: [FaceReuseTarget],
        analysisSignature: String
    ) throws -> [String: ReuseResult]
    func reuseObservationsForAssetFile(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) throws -> ReuseResult
    func upsertAnalysisState(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) throws
    func getClusterSignature(_ sessionId: String) throws -> String?
    func upsertClusterSignature(sessionId: String, signature: String) throws
    func clearClusterSignature(sessionId: String) throws
    func deleteObservationsBySession(_ sessionId: String) throws
    func deleteObservationsByPhoto(sessionId: String, photoId: String) throws
    func deleteAnalysisStateByPhoto(sessionId: String, photoId: String) throws
    func replaceObservationsByPhoto(
        sessionId: String,
        photoId: String,
        observations: [FaceObservationInput]
    ) throws -> [Int64]
    func saveClusters(sessionId: String, clusters: [FaceClusterInput]) throws -> [Int64]
    func getClusters(_ sessionId: String, includeMembers: Bool) throws -> [FaceClusterRow]
    func getClusterMatchRows(sessionId: String, clusterIds: [Int64]) throws -> [FaceRepo.FaceClusterMatchRow]
    func getClusterSessionId(_ clusterId: Int64) throws -> String?
    func getClusterMemberEmbeddings(_ clusterId: Int64) throws -> [ClusterMemberEmbedding]
    func setClusterMatch(clusterId: Int64, personId: String?, confidence: Double?) throws
    func getClusterMembers(_ clusterId: Int64) throws -> [ClusterMemberLite]
    func updateBinding(clusterId: Int64, roleName: String, keywords: [String]) throws
    func deleteBinding(clusterId: Int64) throws
    func mergeClusters(sourceId: Int64, targetId: Int64) throws
    func deleteClustersBySession(_ sessionId: String) throws
    func getBindingsBySession(_ sessionId: String) throws -> [FaceBindingDetail]
    func removeMemberFromCluster(clusterId: Int64, memberId: Int64) throws -> Bool
    func invalidateDerivedResults(sessionId: String, photoIds: [String]) throws
    func getThumbnailPathsBySession(_ sessionId: String) throws -> [String]
}

public extension FaceRepository {
    func getClusters(_ sessionId: String) throws -> [FaceClusterRow] {
        try getClusters(sessionId, includeMembers: false)
    }
}

extension FaceRepo: FaceRepository {}
