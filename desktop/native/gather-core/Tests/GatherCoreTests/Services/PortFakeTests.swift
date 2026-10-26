// desktop/native/gather-core/Tests/GatherCoreTests/Services/PortFakeTests.swift
// WP3b-2b：五个服务的端口注入功能断言（内存 fake/spy，零 SQLite）。
//
// 覆盖目标：Culling / FaceKw / Similarity / Indexer / Settings 每个服务至少一条
// 关键读、写或事务调用，且断言调用确实经过注入端口（而不是服务内部另开连接）。
// 所有 fake 见 PortFakeSupport.swift；本文件不创建 DBConnection / 临时库。
//
// 命名：与既有 *ServiceTests（真实临时 SQLite）区分，便于按套件过滤。

import Foundation
import Testing
import GatherProtocol
@testable import GatherPersistence
import GatherDelivery
import GatherAnalysis
@testable import GatherApplication

// MARK: - Settings

@Suite("WP3b port fakes: SettingsService")
struct PortFakeSettingsServiceTests {
    @Test("loads cache via getAll and persists set/reset through the repository port")
    func cacheAndWrites() throws {
        let repo = PortFakeSettingsRepo(storage: [
            "thumbnail_size": "2048",
            "ui_language": "en",
        ])
        let service = SettingsService(repo: repo)

        // 读：构造时 getAll 全量灌入，get/getAll 只读缓存。
        #expect(repo.getAllCalls == 1)
        #expect(service.get("thumbnail_size") == "2048")
        #expect(service.getAll()["ui_language"] == "en")

        // 写：set 经 repo.upsert 落库并同步缓存。
        try service.set("thumbnail_size", value: "4096")
        #expect(repo.upserts.count == 1)
        #expect(repo.upserts[0].key == "thumbnail_size")
        #expect(repo.upserts[0].value == "4096")
        #expect(service.getNumber("thumbnail_size", defaultValue: 0) == 4096)

        // 写：reset 经 repo.batchUpsert 一次写默认值全量。
        try service.reset()
        #expect(repo.batches.count == 1)
        #expect(repo.batches[0].count == SettingsService.getDefaults().count)
        #expect(service.get("thumbnail_size") == "1024")
        #expect(service.get("ui_language") == "")
    }
}

// MARK: - Indexer

@Suite("WP3b port fakes: IndexerService")
struct PortFakeIndexerServiceTests {
    @Test("checksum backfill reads a page, hashes, then writes in one transaction")
    func checksumBackfill() async throws {
        let photoRepo = PortFakePhotoRepo()
        photoRepo.pendingChecksumCountValue = 1
        photoRepo.pageRows = [
            try portFakePageRow(id: "photo-1", sessionId: "session-1", filepath: "/tmp/photo-1.jpg"),
        ]
        let indexerRepo = PortFakeIndexerRepo()
        let transactions = PortFakeTransactionRunner()
        let service = IndexerService(
            indexer: indexerRepo,
            transactions: transactions,
            sessionRepo: PortFakeSessionRepo(),
            photoRepo: photoRepo,
            assetRepo: PortFakeAssetRepo(),
            faceRepo: nil,
            getDimensions: { _ in (100, 80) },
            getSetting: { _, defaultValue in defaultValue },
            warmMetadata: { _ in }
        )

        // 读：pendingChecksums 走 photoRepo 端口。
        #expect(try service.pendingChecksums(sessionId: "session-1") == 1)

        // 文件 stat / hash 接缝，避免触碰真实文件系统。
        service.stat = { _ in
            (size: 77, mtimeMs: 1_234, dev: 1, ino: 2, isFile: true)
        }
        service.fileHasher = { _ in "hash-1" }

        let result = try await service.backfillChecksums(sessionId: "session-1")

        // 写 + 事务：回填写入在单个 TransactionRunner 作用域内。
        #expect(result.processed == 1)
        #expect(result.backfilled == 1)
        #expect(result.skipped == 0)
        #expect(transactions.transactionCount == 1)
        #expect(indexerRepo.backfillPhotoCalls.count == 1)
        #expect(indexerRepo.backfillPhotoCalls[0].photoId == "photo-1")
        #expect(indexerRepo.backfillPhotoCalls[0].checksum == "hash-1")
        // 读：首趟 nil 游标 + 游标推进后的空页。
        #expect(photoRepo.pageCalls.count >= 2)
        #expect(photoRepo.pageCalls.first! == nil)
    }
}

// MARK: - Culling

@Suite("WP3b port fakes: CullingService")
struct PortFakeCullingServiceTests {
    private func makeService(
        photoRepo: PortFakePhotoRepo,
        decisionRepo: PortFakeCullingDecisionRepo,
        richQuery: PortFakeCullingRichReading,
        transactions: PortFakeTransactionRunner
    ) -> CullingService {
        CullingService(
            photoRepo: photoRepo,
            cullingDecisionRepo: decisionRepo,
            similarityResultRepo: PortFakeSimilarityRepo(),
            metadataCacheRepo: PortFakeMetadataRepo(),
            pageQuery: PortFakeCullingPageReading(),
            richQuery: richQuery,
            deliveryItems: PortFakeDeliveryRepo(),
            transactions: transactions,
            metadataMutations: PortFakeMetadataMutation(),
            writeback: PortFakeCullingWriteback(),
            cullingHistoryRepo: nil,
            delivery: PortFakeDeliveryAdapter(module: .culling)
        )
    }

    @Test("getSummary 只消费 SQL 聚合端口，不再回退到逐行投影")
    func summaryRead() throws {
        let photoRepo = PortFakePhotoRepo()
        let decisionRepo = PortFakeCullingDecisionRepo()
        let richQuery = PortFakeCullingRichReading()
        richQuery.summaryCountsValue = CullingSummaryCounts(
            totalPhotos: 3, kept: 1, rejected: 1, rated: 1, labeled: 1)
        let service = makeService(
            photoRepo: photoRepo,
            decisionRepo: decisionRepo,
            richQuery: richQuery,
            transactions: PortFakeTransactionRunner()
        )

        let summary = try service.getSummary(sessionId: "s1")

        #expect(summary.totalPhotos == 3)
        #expect(summary.kept == 1)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 1)
        #expect(summary.rated == 1)
        #expect(summary.labeled == 1)
        #expect(photoRepo.projectionCalls == 0, "summary 不再回退到 Swift 逐行循环")
    }

    @Test("reset deletes decisions and clears the projection inside one transaction")
    func resetWrite() throws {
        let decisionRepo = PortFakeCullingDecisionRepo()
        decisionRepo.deletedPhotoIds = ["p1", "p2"]
        let richQuery = PortFakeCullingRichReading()
        let transactions = PortFakeTransactionRunner()
        let service = makeService(
            photoRepo: PortFakePhotoRepo(),
            decisionRepo: decisionRepo,
            richQuery: richQuery,
            transactions: transactions
        )

        try service.reset(sessionId: "s1")

        #expect(transactions.transactionCount == 1)
        #expect(decisionRepo.deletedSessions == ["s1"])
        #expect(richQuery.clearedProjectionBatches == [["p1", "p2"]])
    }
}

// MARK: - FaceKw

@Suite("WP3b port fakes: FaceKwService")
struct PortFakeFaceKwServiceTests {
    private func makeService(
        faceRepo: PortFakeFaceRepo,
        feedback: PortFakeFeedbackRepo,
        personRepo: PortFakePersonRepo,
        transactions: PortFakeTransactionRunner
    ) -> FaceKwService {
        FaceKwService(
            photoRepo: PortFakePhotoRepo(),
            sessionRepo: PortFakeSessionRepo(),
            faceRepo: faceRepo,
            personRepo: personRepo,
            feedback: feedback,
            analysisRuns: PortFakeAnalysisRuns(),
            deliveryItems: PortFakeDeliveryRepo(),
            transactions: transactions,
            delivery: PortFakeDeliveryAdapter(module: .faceKeyword)
        )
    }

    @Test("getClusters reads cluster rows and resolves person names")
    func clustersRead() throws {
        let member = portFakeClusterMemberRow(
            id: 11, clusterId: 7, sessionId: "s1",
            photoId: "p1", photoPath: "/p1.NEF"
        )
        let faceRepo = PortFakeFaceRepo()
        faceRepo.clusters = [
            try portFakeClusterRow(
                id: 7, sessionId: "s1", matchedPersonId: "person-1", members: [member]
            ),
        ]
        let personRepo = PortFakePersonRepo()
        personRepo.summariesMap = [
            "person-1": PersonIdentitySummary(id: "person-1", name: "Alice", matchThreshold: 0.65),
        ]
        let service = makeService(
            faceRepo: faceRepo,
            feedback: PortFakeFeedbackRepo(),
            personRepo: personRepo,
            transactions: PortFakeTransactionRunner()
        )

        let clusters = try service.getClusters(sessionId: "s1")

        #expect(clusters.count == 1)
        #expect(clusters[0].id == 7)
        #expect(clusters[0].size == 1)
        #expect(clusters[0].matchedPersonName == "Alice")
        #expect(clusters[0].members.count == 1)
        #expect(clusters[0].members[0].bbox == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("removeMember records feedback and removes the member in one transaction")
    func removeMemberWrite() throws {
        let member = portFakeClusterMemberRow(
            id: 11, clusterId: 7, sessionId: "s1",
            photoId: "p1", photoPath: "/p1.NEF"
        )
        let faceRepo = PortFakeFaceRepo()
        faceRepo.clusters = [try portFakeClusterRow(id: 7, sessionId: "s1", members: [member])]
        faceRepo.clusterSessionIds = [7: "s1"]
        let feedback = PortFakeFeedbackRepo()
        let personRepo = PortFakePersonRepo()
        let transactions = PortFakeTransactionRunner()
        let service = makeService(
            faceRepo: faceRepo,
            feedback: feedback,
            personRepo: personRepo,
            transactions: transactions
        )

        try service.removeMember(sessionId: "s1", clusterId: 7, memberId: 11)

        #expect(transactions.transactionCount == 1)
        #expect(feedback.records.count == 1)
        #expect(feedback.records[0].photoId == "p1")
        #expect(feedback.records[0].confirmed == false)
        #expect(faceRepo.removedMembers.count == 1)
        #expect(faceRepo.removedMembers[0].memberId == 11)
        #expect(personRepo.reconciledSessions == ["s1"])
    }
}

// MARK: - Similarity

@Suite("WP3b port fakes: SimilarityService")
struct PortFakeSimilarityServiceTests {
    private func makeService(
        photoRepo: PortFakePhotoRepo,
        similarityRepo: PortFakeSimilarityRepo,
        clusterStateRepo: PortFakeClusterStateRepo,
        hashes: PortFakeHashes,
        transactions: PortFakeTransactionRunner,
        clusterProvider: @escaping SimilarityService.ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
            try ClusterGraphPipeline.run(
                entries: entries, threshold: threshold,
                minGroupSize: minGroupSize, mode: mode, onProgress: onProgress
            )
        }
    ) -> SimilarityService {
        SimilarityService(
            photoRepo: photoRepo,
            sessionRepo: PortFakeSessionRepo(),
            similarityResultRepo: similarityRepo,
            clusterStateRepo: clusterStateRepo,
            hashes: hashes,
            analysisRuns: PortFakeAnalysisRuns(),
            deliveryItems: PortFakeDeliveryRepo(),
            transactions: transactions,
            clusterProvider: clusterProvider,
            delivery: PortFakeDeliveryAdapter(module: .similarity)
        )
    }

    @Test("getResult rebuilds groups from member rows and live projection")
    func resultRead() throws {
        let similarityRepo = PortFakeSimilarityRepo()
        similarityRepo.latest = try portFakeSimilarityResultRow(
            sessionId: "s1",
            statsJson: #"{"totalGroups":99,"totalUngrouped":99,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#
        )
        similarityRepo.groupMembers = [
            SimilarityGroupMember(groupIndex: 0, photoId: "p1", filepath: "/p1.jpg"),
            SimilarityGroupMember(groupIndex: 0, photoId: "p2", filepath: "/p2.jpg"),
        ]
        let photoRepo = PortFakePhotoRepo()
        photoRepo.projectionRows = [
            try portFakeProjectionRow(id: "p1", sessionId: "s1", filepath: "/p1.jpg"),
            try portFakeProjectionRow(id: "p2", sessionId: "s1", filepath: "/p2.jpg"),
            try portFakeProjectionRow(id: "p3", sessionId: "s1", filepath: "/p3.jpg"),
        ]
        let service = makeService(
            photoRepo: photoRepo,
            similarityRepo: similarityRepo,
            clusterStateRepo: PortFakeClusterStateRepo(),
            hashes: PortFakeHashes(),
            transactions: PortFakeTransactionRunner()
        )

        let maybe = try service.getResult(sessionId: "s1")
        let result = try #require(maybe)

        #expect(result.groups.count == 1)
        #expect(result.groups[0].count == 2)
        #expect(result.groups[0].images.map(\.path) == ["/p1.jpg", "/p2.jpg"])
        #expect(result.ungrouped.map(\.path) == ["/p3.jpg"])
        // 统计按本次实时重建的成员表/投影重算，不沿用落库快照。
        #expect(result.stats.totalGroups == 1)
        #expect(result.stats.totalUngrouped == 1)
        #expect(similarityRepo.memberCalls == 1)
        #expect(photoRepo.projectionCalls == 1)
    }

    @Test("recluster persists result and cluster-state update in one transaction")
    func reclusterWrite() async throws {
        let similarityRepo = PortFakeSimilarityRepo()
        similarityRepo.latest = try portFakeSimilarityResultRow(sessionId: "s1")
        let photoRepo = PortFakePhotoRepo()
        photoRepo.projectionRows = [
            try portFakeProjectionRow(id: "p1", sessionId: "s1", filepath: "/p1.jpg"),
        ]
        let hashes = PortFakeHashes()
        hashes.hashMap = ["p1": "0000000000000000"]
        let clusterStateRepo = PortFakeClusterStateRepo()
        let transactions = PortFakeTransactionRunner()
        let signal = JobAbortSignal()
        let service = makeService(
            photoRepo: photoRepo,
            similarityRepo: similarityRepo,
            clusterStateRepo: clusterStateRepo,
            hashes: hashes,
            transactions: transactions,
            clusterProvider: { _, _, _, _, _ in
                ClusterGraphOutcome(
                    result: ClusterResult(groups: [], ungrouped: ["p1"]),
                    state: nil
                )
            }
        )

        // cluster-done 后 abort：主结果已具备提交条件，提前结束邻域档位预计算。
        let result = try await service.recluster(
            sessionId: "s1",
            threshold: 10,
            minGroupSize: 2,
            signal: signal,
            onProgress: { _, _, phase in
                if phase == "similarity.cluster-done" { signal.abort() }
            }
        )

        #expect(result.ungrouped.map(\.path) == ["/p1.jpg"])
        #expect(transactions.transactionCount == 1)
        #expect(similarityRepo.replaceCalls == 1)
        #expect(similarityRepo.lastReplaceThreshold == 10)
        #expect(clusterStateRepo.deleteCalls == 1)
        #expect(hashes.getHashMapCalls == 1)
    }
}
