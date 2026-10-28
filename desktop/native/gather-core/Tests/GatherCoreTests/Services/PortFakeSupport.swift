// desktop/native/gather-core/Tests/GatherCoreTests/Services/PortFakeSupport.swift
// WP3b fake-repo 功能断言：内存端口替身（shared helpers）。
//
// 这里只放测试替身与行构造器：不打开 DBConnection、不创建临时 SQLite、不触碰
// XMP/文件系统。每个替身都记录关键调用，供 PortFakeTests.swift 断言
// 「服务确实经端口读/写/事务」而不是绕过端口。
//
// 说明：
// - 未参与本轮用例的协议方法统一抛 PortFakeError.unimplemented，避免静默
//   返回空值掩盖端口漂移；测试一旦走到未覆盖路径会立刻失败。
// - 协议里没有 Sendable 约束的替身保持普通 final class；有 Sendable 约束的
//   （DeliveryModuleAdapter / DeliveryEngine / MetadataMutationPort）标
//   @unchecked Sendable（测试串行执行，类内可变只做记录）。

import Foundation
import GatherProtocol
@testable import GatherPersistence
import GatherDelivery
import GatherAnalysis
import GatherApplication

enum PortFakeError: Error, CustomStringConvertible {
    case unimplemented(String)

    var description: String {
        switch self {
        case .unimplemented(let name): return "PORT_FAKE_UNIMPLEMENTED: \(name)"
        }
    }
}

// MARK: - 事务

/// TransactionRunner 记录型替身：执行闭包并计数。
final class PortFakeTransactionRunner: TransactionRunner {
    private(set) var transactionCount = 0

    func transaction<T>(_ body: () throws -> T) throws -> T {
        transactionCount += 1
        return try body()
    }
}

// MARK: - Settings

final class PortFakeSettingsRepo: SettingsRepository {
    var storage: [String: String]
    private(set) var upserts: [(key: String, value: String)] = []
    private(set) var batches: [[(key: String, value: String)]] = []
    private(set) var getAllCalls = 0

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    func getAll() throws -> [SettingsRow] {
        getAllCalls += 1
        return storage
            .sorted { $0.key < $1.key }
            .map { SettingsRow(key: $0.key, value: $0.value) }
    }

    func upsert(key: String, value: String) throws {
        upserts.append((key: key, value: value))
        storage[key] = value
    }

    func batchUpsert(entries: [(key: String, value: String)]) throws {
        batches.append(entries)
        for entry in entries {
            storage[entry.key] = entry.value
        }
    }
}

// MARK: - Photo / Session / Asset

final class PortFakePhotoRepo: PhotoRepository {
    var projectionRows: [PhotoProjectionRow] = []
    var pageRows: [PhotoPageRow] = []
    var pendingChecksumCountValue = 0
    private(set) var pageCalls: [Int64?] = []
    private(set) var projectionCalls = 0
    private(set) var checksumUpdates: [(photoId: String, checksum: String, fileSize: Int, mtimeMs: Double)] = []

    func getBySession(sessionId: String) throws -> [PhotoRow] { [] }

    /// P1 / D：淘汰移动的路径回写（fake 只记录，不改行）。
    private(set) var filepathUpdates: [(photoId: String, filepath: String)] = []

    func updateFilepath(photoId: String, filepath: String) throws {
        filepathUpdates.append((photoId, filepath))
    }

    func getBySessionProjection(sessionId: String) throws -> [PhotoProjectionRow] {
        projectionCalls += 1
        return projectionRows
    }

    func getBySessionPage(
        sessionId: String, afterRowId: Int64?, limit: Int, visibleOnly: Bool
    ) throws -> [PhotoPageRow] {
        pageCalls.append(afterRowId)
        // 首趟返回一页；keyset 游标推进后无更多待回填行。
        return afterRowId == nil ? pageRows : []
    }

    func pendingChecksumCount(sessionId: String) throws -> Int {
        pendingChecksumCountValue
    }

    func countBySession(sessionId: String) throws -> Int { projectionRows.count }
    func countVisibleBySession(sessionId: String) throws -> Int {
        projectionRows.filter { $0.archivedAt == nil }.count
    }
    func countAssetsBySession(sessionId: String) throws -> Int { 0 }

    func getAssetPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?) {
        ([], nil)
    }

    func addPhotos(sessionId: String, filepaths: [PhotoAddInput], _ source: String) throws -> PhotoAddResult {
        throw PortFakeError.unimplemented("PhotoRepository.addPhotos")
    }

    func deleteBySession(sessionId: String) throws {}
    func updateIndexedFile(photoId: String, width: Int, height: Int, changed: Bool) throws {}
    func updateChecksum(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double) throws {
        checksumUpdates.append((photoId, checksum, fileSize, fileMtimeMs))
    }
    func markMissing(photoIds: [String]) throws {}
    func countByStatus(sessionId: String, status: String) throws -> Int { 0 }
    func getLookupByIds(_ photoIds: [String]) throws -> [PhotoLookupRow] { [] }
    func reportRows(sessionId: String) throws -> [PhotoReportRow] { [] }
}

final class PortFakeSessionRepo: SessionRepository {
    var indexSeq = 0

    func get(id: String) throws -> SessionRow? { nil }

    func create(name: String, source: String, sourcePath: String, truncatedImport: Bool) throws -> SessionRow {
        throw PortFakeError.unimplemented("SessionRepository.create")
    }

    func list() throws -> [SessionRow] { [] }
    func delete(id: String) throws -> Bool { false }
    func deleteMany(ids: [String]) throws -> Int { 0 }
    func deleteSimilarityDataBySession(sessionId: String) throws {}
    func updateName(id: String, name: String) throws -> Bool { false }
    func updateStatus(id: String, status: String) throws {}
    func updatePhotoCount(id: String, count: Int) throws {}
    func getIndexSeq(id: String) throws -> Int { indexSeq }
    func bumpIndexSeq(id: String) throws -> Int { indexSeq += 1; return indexSeq }
    func latestAnalysisRun(sessionId: String, kind: String) throws -> AnalysisRunRecord? { nil }
    func markOrphanedAssets() throws {}
}

final class PortFakeAssetRepo: AssetRepository {
    func backfillSession(_ sessionId: String) throws -> BackfillResult {
        throw PortFakeError.unimplemented("AssetRepository.backfillSession")
    }

    func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        fileIdentity: String
    ) throws -> RelinkMovedFileResult? { nil }

    func markOrphanedAssets() throws {}
}

// MARK: - Metadata

final class PortFakeMetadataRepo: MetadataRepository {
    var batchRows: [MetadataCacheRow] = []
    private(set) var ratingUpdates: [String: Int64] = [:]
    private(set) var labelUpdates: [String: String] = [:]

    func upsert(photoId: String, sessionId: String, data: MetadataCacheInput) throws {}
    func get(_ photoId: String) throws -> MetadataCacheRow? { nil }
    func getBatch(_ photoIds: [String]) throws -> [MetadataCacheRow] { batchRows }
    func deleteBySession(_ sessionId: String) throws {}
    func updateRating(photoId: String, rating: Int64) throws { ratingUpdates[photoId] = rating }
    func updateLabel(photoId: String, label: String) throws { labelUpdates[photoId] = label }
    func updateKeywords(photoId: String, keywords: [String]) throws {}
    /// P1 / IPTC：记录描述性元数据投影（模板/triage 写后刷新的断言点）。
    private(set) var descriptiveUpdates: [String: DescriptiveMetadata] = [:]
    func updateDescriptive(photoId: String, descriptive: DescriptiveMetadata) throws {
        descriptiveUpdates[photoId] = descriptive
    }
    private(set) var descriptiveMerges: [(photoId: String, patch: DescriptiveMetadata)] = []
    func mergeDescriptive(
        photoId: String, patch: DescriptiveMetadata, replaceContact: Bool
    ) throws {
        descriptiveMerges.append((photoId, patch))
    }
}

final class PortFakeMetadataMutation: MetadataMutationPort, @unchecked Sendable {
    private(set) var queuedValues: [(sessionId: String, photoId: String, values: [String: JSONValue])] = []

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        queuedValues.append((sessionId, photoId, values))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }

}

// MARK: - Delivery

final class PortFakeDeliveryRepo: DeliveryRepository {
    var items: [DeliveryItemRow] = []
    var rowByPath: [String: DeliveryRow] = [:]
    private(set) var listCalls = 0

    func listItems(
        sessionId: String,
        module: DeliveryModule?,
        status: DeliveryItemStatus?
    ) throws -> [DeliveryItemRow] {
        listCalls += 1
        return items
    }

    func getItem(xmpPath: String) throws -> DeliveryRow? { rowByPath[xmpPath] }
    func getMany(xmpPaths: [String]) throws -> [String: DeliveryRow] {
        rowByPath.filter { xmpPaths.contains($0.key) }
    }
}

final class PortFakeDeliveryEngine: DeliveryEngine, @unchecked Sendable {
    func confirm(sessionId: String, module: DeliveryModule) throws -> DeliveryConfirmSummary {
        throw PortFakeError.unimplemented("DeliveryEngine.confirm")
    }

    func cleanup(sessionId: String, module: DeliveryModule) async throws -> DeliveryCleanupSummary {
        throw PortFakeError.unimplemented("DeliveryEngine.cleanup")
    }

    func finalize(sessionId: String, module: DeliveryModule) async throws -> DeliveryFinalizeSummary {
        throw PortFakeError.unimplemented("DeliveryEngine.finalize")
    }

    func mirrorWriteback(
        sessionId: String,
        module: DeliveryModule,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        throw PortFakeError.unimplemented("DeliveryEngine.mirrorWriteback")
    }

    func metadataSummary(sessionId: String, module: DeliveryModule?) throws -> MetadataSyncSummary {
        throw PortFakeError.unimplemented("DeliveryEngine.metadataSummary")
    }

    func replay() async throws -> DeliveryReplaySummary {
        throw PortFakeError.unimplemented("DeliveryEngine.replay")
    }
}

final class PortFakeDeliveryAdapter: DeliveryModuleAdapter, @unchecked Sendable {
    let module: DeliveryModule
    let capabilities: Set<DeliveryModuleCapability>
    let engine: any DeliveryEngine

    init(module: DeliveryModule = .culling) {
        self.module = module
        self.capabilities = DeliveryModuleCapability.capabilities(for: module)
        self.engine = PortFakeDeliveryEngine()
    }

    func confirm(sessionId: String) throws -> DeliveryConfirmSummary {
        throw PortFakeError.unimplemented("DeliveryModuleAdapter.confirm")
    }

    func cleanup(sessionId: String) async throws -> DeliveryCleanupSummary {
        throw PortFakeError.unimplemented("DeliveryModuleAdapter.cleanup")
    }

    func finalize(sessionId: String) async throws -> DeliveryFinalizeSummary {
        throw PortFakeError.unimplemented("DeliveryModuleAdapter.finalize")
    }

    func mirrorWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        throw PortFakeError.unimplemented("DeliveryModuleAdapter.mirrorWriteback")
    }

    func metadataSummary(sessionId: String) throws -> MetadataSyncSummary {
        throw PortFakeError.unimplemented("DeliveryModuleAdapter.metadataSummary")
    }
}

final class PortFakeCullingWriteback: CullingWritebackPort {
    func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions,
        photoIds: Set<String>?,
        keywordAdditions: [String: [String]]?
    ) async throws -> WritebackPreview {
        throw PortFakeError.unimplemented("CullingWritebackPort.preview")
    }

    func persistAttributes(items: [WritebackItem]) throws {
        throw PortFakeError.unimplemented("CullingWritebackPort.persistAttributes")
    }

    func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult {
        throw PortFakeError.unimplemented("CullingWritebackPort.execute")
    }

    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult {
        throw PortFakeError.unimplemented("CullingWritebackPort.retryFailed")
    }

    func getItems(sessionId: String, module: String, status: String?) throws -> [WritebackItem] {
        throw PortFakeError.unimplemented("CullingWritebackPort.getItems")
    }

    func confirmSync(sessionId: String, module: String) async throws {
        throw PortFakeError.unimplemented("CullingWritebackPort.confirmSync")
    }

    func cleanup(sessionId: String, module: String) async throws -> CleanupResult {
        throw PortFakeError.unimplemented("CullingWritebackPort.cleanup")
    }
}

// MARK: - Culling 读模型 / 决策

final class PortFakeCullingPageReading: CullingPageReading {
    func pageSorted(
        sessionId: String,
        scope: CullingScope,
        filter: CullingPageFilter,
        similarity: CullingSimilarityScope?,
        sort: CullingSort,
        cursor: CullingPageCursor?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: CullingPageCursor?) { ([], nil) }

    func countFiltered(sessionId: String, filter: CullingPageFilter) throws -> Int { 0 }
    func countSimilarity(sessionId: String, similarity: CullingSimilarityScope) throws -> Int { 0 }

    func representativeIds(
        sessionId: String,
        scope: CullingScope,
        filter: CullingPageFilter,
        similarity: CullingSimilarityScope?,
        limit: Int
    ) throws -> (ids: [String], truncated: Bool) { ([], false) }
}

final class PortFakeCullingRichReading: CullingRichReading {
    var summaryCountsValue = CullingSummaryCounts(
        totalPhotos: 0, kept: 0, rejected: 0, rated: 0, labeled: 0)
    private(set) var clearedProjectionBatches: [[String]] = []

    func qualityRows(photoIds: [String]) throws -> [CullingQualityResultRow] { [] }
    func triageRows(sessionId: String) throws -> [CullingTriageRow] { [] }
    func triageRows(sessionId: String, photoIds: [String]) throws -> [CullingTriageRow] { [] }

    func faceRows(sessionId: String) throws -> [CullingFaceObservationRow] { [] }
    func faceRows(sessionId: String, photoIds: [String]) throws -> [CullingFaceObservationRow] { [] }
    func personRows(sessionId: String) throws -> [CullingPersonNameRow] { [] }
    func personRows(sessionId: String, photoIds: [String]) throws -> [CullingPersonNameRow] { [] }
    func deliveryModuleRows(xmpPaths: [String]) throws -> [CullingDeliveryModuleRow] { [] }
    func conflictPhotoPaths(sessionId: String) throws -> Set<String> { [] }

    func existingPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String> {
        Set(photoIds)
    }

    func summaryCounts(sessionId: String, colorLabels: [String]) throws -> CullingSummaryCounts {
        summaryCountsValue
    }

    func clearCullingProjection(photoIds: [String]) throws {
        clearedProjectionBatches.append(photoIds)
    }
}

final class PortFakeCullingDecisionRepo: CullingDecisionRepository {
    var decisions: [CullingDecisionRow] = []
    var deletedPhotoIds: [String] = []
    private(set) var deletedSessions: [String] = []
    private(set) var upsertedStates: [(sessionId: String, photoId: String, decision: String, revision: Int64)] = []

    func getDecisions(_ sessionId: String) throws -> [CullingDecisionLiteRow] {
        decisions
            .filter { $0.sessionId == sessionId }
            .map { CullingDecisionLiteRow(photoId: $0.photoId, decision: $0.decision) }
    }

    func getBySession(_ sessionId: String) throws -> [CullingDecisionRow] {
        decisions.filter { $0.sessionId == sessionId }
    }

    func getByPhotoIds(sessionId: String, photoIds: [String]) throws -> [CullingDecisionRow] {
        decisions.filter { $0.sessionId == sessionId && photoIds.contains($0.photoId) }
    }

    func getDecision(sessionId: String, photoId: String) throws -> CullingDecisionRow? {
        decisions.first { $0.sessionId == sessionId && $0.photoId == photoId }
    }

    func upsertState(
        sessionId: String,
        photoId: String,
        groupId: String,
        state: CullingDecisionStateInput
    ) throws {
        upsertedStates.append((sessionId, photoId, state.decision, state.revision))
    }

    func deleteBySession(_ sessionId: String) throws -> [String] {
        deletedSessions.append(sessionId)
        return deletedPhotoIds
    }

    func deleteBySessionAndGroup(sessionId: String, groupId: String) throws -> [String] {
        deletedSessions.append(sessionId)
        return deletedPhotoIds
    }
}

// MARK: - Similarity

final class PortFakeSimilarityRepo: SimilarityRepository {
    var latest: SimilarityResultRow?
    var groupMembers: [SimilarityGroupMember]?
    private(set) var latestCalls = 0
    private(set) var memberCalls = 0
    private(set) var replaceCalls = 0
    private(set) var replaceForThresholdCalls = 0
    private(set) var lastReplaceThreshold: Int?
    private(set) var lastReplaceMemberships: [(photoId: String, groupIndex: Int)] = []

    func getLatest(sessionId: String) throws -> SimilarityResultRow? {
        latestCalls += 1
        return latest
    }

    func getByThreshold(sessionId: String, threshold: Int) throws -> SimilarityResultRow? { nil }

    func replace(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64 {
        replaceCalls += 1
        lastReplaceThreshold = threshold
        lastReplaceMemberships = memberships
        return 42
    }

    func replaceForThreshold(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64 {
        replaceForThresholdCalls += 1
        return 43
    }

    func getPhotoGroupMap(sessionId: String, resultId: Int64) throws -> [String: String] { [:] }

    func getGroupMembers(sessionId: String, resultId: Int64) throws -> [SimilarityGroupMember]? {
        memberCalls += 1
        return groupMembers
    }

    func groupMemberCounts(sessionId: String, resultId: Int64) throws -> [Int: Int] { [:] }
    func countFullyArchivedGroups(sessionId: String, resultId: Int64) throws -> Int { 0 }
}

final class PortFakeClusterStateRepo: SimilarityClusterStateRepository {
    private(set) var loadCalls = 0
    private(set) var applyCalls = 0
    private(set) var deleteCalls = 0

    func load(sessionId: String) throws -> SimilarityClusterSnapshot? {
        loadCalls += 1
        return nil
    }

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
    ) throws {
        applyCalls += 1
    }

    func delete(sessionId: String) throws {
        deleteCalls += 1
    }
}

final class PortFakeHashes: SimilarityHashRepository {
    var hashMap: [String: String] = [:]
    private(set) var getHashMapCalls = 0
    private(set) var upserted: [SimilarityHashWrite] = []

    func getRecords(sessionId: String) throws -> [SimilarityHashRecord] { [] }

    func getHashMap(sessionId: String) throws -> [String: String] {
        getHashMapCalls += 1
        return hashMap
    }

    func upsert(_ rows: [SimilarityHashWrite]) throws {
        upserted.append(contentsOf: rows)
    }

    func getPhotoAssetFileIds(sessionId: String) throws -> [PhotoAssetFileRef] { [] }
    func getReuseCandidates(assetFileIds: [String]) throws -> [SimilarityHashCandidate] { [] }
    func deleteByPhotoIds(_ photoIds: [String]) throws {}
}

final class PortFakeAnalysisRuns: AnalysisRunRepository {
    private(set) var started = 0
    private(set) var finished: [Int64] = []

    func start(
        sessionId: String,
        kind: String,
        photoCount: Int,
        indexSeq: Int,
        paramsJson: String
    ) throws -> Int64 {
        started += 1
        return Int64(started)
    }

    func finish(runId: Int64, status: String) throws {
        finished.append(runId)
    }
}

// MARK: - Indexer

final class PortFakeIndexerRepo: IndexerRepository {
    private(set) var backfillPhotoCalls: [(photoId: String, checksum: String, fileSize: Int64)] = []
    private(set) var backfillAssetFileCalls: [(assetFileId: String, checksum: String)] = []

    func deletePersonPhotoBindings(photoIds: [String]) throws {}
    func deletePhotos(photoIds: [String]) throws {}
    func pruneSessionAssets(sessionId: String) throws {}
    func pruneOrphanAssets(fileIds: [String]) throws {}
    func fileStats(sessionId: String) throws -> [AssetFileStatRow] { [] }

    func updateAssetFile(
        assetFileId: String,
        volumeId: String,
        fileIdentity: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        checksum: String,
        preserveChecksum: Bool,
        timestamp: String
    ) throws {}

    func photoIds(assetFileId: String) throws -> [String] { [] }
    func deleteAssetAnalysis(assetFileId: String) throws {}

    func updatePhotos(
        assetFileId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        width: Int,
        height: Int,
        timestamp: String
    ) throws {}

    func markAssetFilesOffline(fileIds: [String], timestamp: String) throws {}

    func backfillPhotoChecksum(
        photoId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        timestamp: String
    ) throws -> Bool {
        backfillPhotoCalls.append((photoId, checksum, fileSize))
        return true
    }

    func backfillAssetFileChecksum(
        assetFileId: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        timestamp: String
    ) throws {
        backfillAssetFileCalls.append((assetFileId, checksum))
    }

    func deletePhotoInputs(photoIds: [String]) throws {}

    func automaticNavigationGroups(
        sessionId: String,
        photoIds: [String],
        prefilterCap: Int
    ) throws -> [AutomaticNavigationGroupRow] { [] }

    func deleteNavigationGroups(ids: [String]) throws {}
    func deleteSimilarityResults(sessionId: String) throws {}
    func sessionIds(photoIds: [String]) throws -> Set<String> { [] }
    func photoIdsBySession(photoIds: [String]) throws -> [String: [String]] { [:] }
}

// MARK: - Face / Person / Feedback

final class PortFakeFaceRepo: FaceRepository {
    var clusters: [FaceClusterRow] = []
    var clusterSessionIds: [Int64: String] = [:]
    private(set) var removedMembers: [(clusterId: Int64, memberId: Int64)] = []

    func getObservations(_ sessionId: String) throws -> [FaceObservationRow] { [] }
    func countsByPhoto(sessionId: String, photoIds: [String]) throws -> [String: Int] { [:] }
    func getAnalysisStates(_ sessionId: String) throws -> [String: FaceAnalysisState] { [:] }

    func reuseObservationsForAssetFile(
        sessionId: String,
        targets: [FaceReuseTarget],
        analysisSignature: String
    ) throws -> [String: ReuseResult] { [:] }

    func reuseObservationsForAssetFile(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) throws -> ReuseResult {
        throw PortFakeError.unimplemented("FaceRepository.reuseObservationsForAssetFile")
    }

    func upsertAnalysisState(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) throws {}

    func getClusterSignature(_ sessionId: String) throws -> String? { nil }
    func upsertClusterSignature(sessionId: String, signature: String) throws {}
    func clearClusterSignature(sessionId: String) throws {}
    func deleteObservationsBySession(_ sessionId: String) throws {}
    func deleteObservationsByPhoto(sessionId: String, photoId: String) throws {}
    func deleteAnalysisStateByPhoto(sessionId: String, photoId: String) throws {}

    func replaceObservationsByPhoto(
        sessionId: String,
        photoId: String,
        observations: [FaceObservationInput]
    ) throws -> [Int64] { [] }

    func saveClusters(sessionId: String, clusters: [FaceClusterInput]) throws -> [Int64] { [] }

    func getClusters(_ sessionId: String, includeMembers: Bool) throws -> [FaceClusterRow] {
        clusters
    }

    func getClusterMatchRows(
        sessionId: String,
        clusterIds: [Int64]
    ) throws -> [FaceRepo.FaceClusterMatchRow] { [] }

    func getClusterSessionId(_ clusterId: Int64) throws -> String? {
        clusterSessionIds[clusterId]
    }

    func getClusterMemberEmbeddings(_ clusterId: Int64) throws -> [ClusterMemberEmbedding] { [] }
    func setClusterMatch(clusterId: Int64, personId: String?, confidence: Double?) throws {}
    func getClusterMembers(_ clusterId: Int64) throws -> [ClusterMemberLite] { [] }
    func updateBinding(clusterId: Int64, roleName: String, keywords: [String]) throws {}
    func deleteBinding(clusterId: Int64) throws {}
    func mergeClusters(sourceId: Int64, targetId: Int64) throws {}
    func deleteClustersBySession(_ sessionId: String) throws {}
    func getBindingsBySession(_ sessionId: String) throws -> [FaceBindingDetail] { [] }

    func removeMemberFromCluster(clusterId: Int64, memberId: Int64) throws -> Bool {
        removedMembers.append((clusterId, memberId))
        return true
    }

    func invalidateDerivedResults(sessionId: String, photoIds: [String]) throws {}
    func getThumbnailPathsBySession(_ sessionId: String) throws -> [String] { [] }
    func clearClusterMembers(sessionId: String) throws {}
    func deleteUnboundClusters(sessionId: String) throws {}

    func appendClusterMembers(
        sessionId: String,
        groups: [(clusterId: Int64, members: [FaceClusterMemberInput])]
    ) throws {}

    func deleteClusterMembers(ids: [Int64]) throws {}

    // F0 真实契约：fake 显式实现，写路径未模拟时必须抛错而不是静默成功。
    func isClusterBound(clusterId: Int64) throws -> Bool { false }
    func createCluster(sessionId: String, label: String) throws -> Int64 {
        throw PortFakeError.unimplemented("FaceRepository.createCluster")
    }
    func moveClusterMembers(
        memberIds: [Int64], toClusterId: Int64, sessionId: String
    ) throws -> Int {
        throw PortFakeError.unimplemented("FaceRepository.moveClusterMembers")
    }
    func moveClusterMembers(
        memberIds: [Int64], toClusterId: Int64, sessionId: String, expectedClusterId: Int64
    ) throws -> Int {
        throw PortFakeError.unimplemented("FaceRepository.moveClusterMembers(expected)")
    }
    func getClusterLabels(sessionId: String) throws -> [String] { [] }
    func getClusterMembersFull(clusterId: Int64) throws -> [FaceClusterMemberRecord] { [] }
    func getReviewMembers(sessionId: String, clusterIds: [Int64]) throws -> [FaceReviewMemberRow] { [] }
    func reviewRevision(sessionId: String) throws -> String? { nil }
    func getConstraints(sessionId: String) throws -> [FaceClusterConstraintRow] { [] }
    func insertConstraint(
        sessionId: String,
        kind: FaceClusterConstraintKind,
        memberKeys: [FaceClusterConstraintKey],
        peerKeys: [FaceClusterConstraintKey]
    ) throws -> Int64 {
        throw PortFakeError.unimplemented("FaceRepository.insertConstraint")
    }
    func updateConstraintKeys(
        id: Int64,
        memberKeys: [FaceClusterConstraintKey],
        peerKeys: [FaceClusterConstraintKey]
    ) throws {
        throw PortFakeError.unimplemented("FaceRepository.updateConstraintKeys")
    }
    func deleteConstraint(id: Int64) throws {
        throw PortFakeError.unimplemented("FaceRepository.deleteConstraint")
    }
    func deleteConstraints(ids: [Int64]) throws {
        throw PortFakeError.unimplemented("FaceRepository.deleteConstraints(ids)")
    }
    func deleteConstraints(sessionId: String) throws {
        throw PortFakeError.unimplemented("FaceRepository.deleteConstraints(session)")
    }
    func deleteEmptyUnboundClusters(ids: [Int64]) throws -> Int {
        throw PortFakeError.unimplemented("FaceRepository.deleteEmptyUnboundClusters")
    }
    func markClustersUnbound(ids: [Int64]) throws {
        throw PortFakeError.unimplemented("FaceRepository.markClustersUnbound")
    }
    func touchClusters(ids: [Int64]) throws {
        throw PortFakeError.unimplemented("FaceRepository.touchClusters")
    }
}

final class PortFakeFeedbackRepo: FaceFeedbackRepository {
    private(set) var records: [(sessionId: String, photoId: String, personId: String?, confirmed: Bool)] = []
    private(set) var forgets: [(sessionId: String, photoId: String)] = []

    func list(sessionId: String) throws -> [FaceIdentityFeedback] { [] }

    func record(
        sessionId: String,
        photoId: String,
        bbox: [Double],
        personId: String?,
        confirmed: Bool,
        keywords: [String]
    ) throws {
        records.append((sessionId, photoId, personId, confirmed))
    }

    func forgetConfirmation(
        sessionId: String,
        photoId: String,
        bbox: [Double],
        personId: String?
    ) throws {
        forgets.append((sessionId, photoId))
    }
}

final class PortFakePersonRepo: PersonRepository {
    var summariesMap: [String: PersonIdentitySummary] = [:]
    private(set) var reconciledSessions: [String] = []

    func summaries(ids: [String]) throws -> [String: PersonIdentitySummary] { summariesMap }
    func get(id: String) throws -> PersonRow? { nil }

    func upsertByName(name: String, keywords: [String]?) throws -> String {
        throw PortFakeError.unimplemented("PersonRepository.upsertByName")
    }

    func bindRole(
        clusterId: Int64,
        sessionId: String,
        roleName: String,
        keywords: [String],
        members: [PersonPhotoInput]
    ) throws -> PersonIdentityOutcome {
        throw PortFakeError.unimplemented("PersonRepository.bindRole")
    }

    func reconcileSession(sessionId: String) throws {
        reconciledSessions.append(sessionId)
    }

    func saveEmbeddings(embeddings: [SaveEmbeddingInput]) throws {}
    func getAllEmbeddings(modelSpace: String?) throws -> [PersonEmbeddingRef] { [] }
    func deleteSessionRows(sessionId: String) throws {}
}

// MARK: - 行构造器

func portFakeProjectionRow(
    id: String,
    sessionId: String,
    filepath: String,
    assetId: String? = nil
) throws -> PhotoProjectionRow {
    try PhotoProjectionRow(row: [
        .text(id), .text(sessionId), .text(filepath),
        .text((filepath as NSString).lastPathComponent), .text(""),
        .int(0), .real(0), .text("pending"),
        assetId.map { .text($0) } ?? .null, .null,
        .int(100), .int(80), .text("2026-01-01T00:00:00.000Z"),
        .text("2026-01-01T00:00:00.000Z"), .null,
    ])
}

func portFakePageRow(
    rowid: Int64 = 5,
    id: String,
    sessionId: String,
    filepath: String,
    checksum: String? = nil
) throws -> PhotoPageRow {
    try PhotoPageRow(row: [
        .int(rowid), .text(id), .text(sessionId), .text(filepath),
        .text((filepath as NSString).lastPathComponent), .text("pending"),
        .null, .null, .int(100), .int(80),
        checksum.map { .text($0) } ?? .null,
        .text("2026-01-01T00:00:00.000Z"), .text("2026-01-01T00:00:00.000Z"),
    ])
}

func portFakeDecisionRow(
    id: Int64 = 1,
    sessionId: String,
    photoId: String,
    decision: String,
    revision: Int64 = 0
) throws -> CullingDecisionRow {
    CullingDecisionRow(row: [
        .int(id), .text(sessionId), .text(photoId), .text("ungrouped"),
        .text(decision), .int(0), .text("None"), .text("manual"),
        .int(revision), .text("2026-01-01T00:00:00.000Z"),
        .text("2026-01-01T00:00:00.000Z"),
    ])
}

func portFakeSimilarityResultRow(
    id: Int64 = 7,
    sessionId: String,
    statsJson: String = #"{"totalGroups":0,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
    groupsJson: String = #"{"groups":[],"ungrouped":[]}"#
) throws -> SimilarityResultRow {
    try SimilarityResultRow(row: [
        .int(id), .text(sessionId), .text(groupsJson), .text(statsJson),
        .int(10), .int(2), .text("2026-01-01T00:00:00.000Z"),
    ])
}

func portFakeClusterRow(
    id: Int64,
    sessionId: String,
    matchedPersonId: String? = nil,
    members: [FaceClusterMemberRow] = []
) throws -> FaceClusterRow {
    var cluster = try FaceClusterRow(row: [
        .int(id), .text(sessionId), .text("Person"), .int(Int64(members.count)),
        .text("active"), .text(""), matchedPersonId.map { .text($0) } ?? .null,
        .null, .text("2026-01-01T00:00:00.000Z"), .text("2026-01-01T00:00:00.000Z"),
    ])
    cluster.members = members
    return cluster
}

func portFakeClusterMemberRow(
    id: Int64,
    clusterId: Int64,
    sessionId: String,
    photoId: String,
    photoPath: String,
    bbox: String = "[0.1,0.2,0.3,0.4]",
    confidence: Double = 0.9
) -> FaceClusterMemberRow {
    FaceClusterMemberRow(row: [
        .int(id), .int(clusterId), .text(sessionId), .text(photoId),
        .text(photoPath), .text(bbox), .real(confidence), .null,
    ])
}
