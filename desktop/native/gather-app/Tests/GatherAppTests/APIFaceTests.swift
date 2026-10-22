// desktop/native/gather-app/Tests/GatherAppTests/APIFaceTests.swift
// R1 P1-2：此前只有 Stub 接线、没有 Live 行为测试的 3 个 FaceAPI 方法。
//
// 覆盖：
// - merge（fkw.merge）：源簇成员并入目标簇、源簇行消失；不存在的簇显式失败；
// - removeMember（fkw.remove_member）：成员清单/大小收敛，最后一个成员移除后
//   无绑定簇行被删除，成员缺失报 FKW_CLUSTER_MEMBER_NOT_FOUND；
// - cancelAnalysis（fkw.cancel_analysis）：只取消本会话的 faceAnalyze job，
//   其它会话/其它类型不受影响；裸 sessionId 走 INVALID_PARAM。
//
// 夹具：内存 SchemaV1 库 + 真实 FaceKwService / JobService / SessionRepo；
// 不写文件、不跑推理（三个被测方法都不需要模型或写回提供者），每个用例独立
// 新建库与 service，不共享全局状态。JobService 不 start()，避免后台看门狗
// 线程；queued job 的取消不需要调度器参与。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

private struct FaceBehaviorFixture {
    let db: DBConnection
    let sessionId: String
    let photoIds: [String]
    let faceRepo: FaceRepo
    let jobService: JobService
    let faceAPI: LiveFaceAPI
    /// 簇 A（2 名成员）、簇 B（1 名成员），顺序与 saveClusters 入参一致。
    let clusters: [Int64]

    init() throws {
        let db = try makeGatherTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "R1P1-2 Face", source: "test")
        let photoRepo = PhotoRepo(connection: db)
        let photoIds = try photoRepo.addPhotos(
            sessionId: session.id,
            filepaths: [
                PhotoAddInput(filepath: "/shoot/a.jpg", width: 100, height: 100),
                PhotoAddInput(filepath: "/shoot/b.jpg", width: 100, height: 100),
                PhotoAddInput(filepath: "/shoot/c.jpg", width: 100, height: 100),
                PhotoAddInput(filepath: "/shoot/d.jpg", width: 100, height: 100),
            ],
            "test"
        ).ids
        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let faceKwService = FaceKwService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            faceRepo: faceRepo,
            personRepo: personRepo,
            connection: db
        )
        let clusters = try faceRepo.saveClusters(
            sessionId: session.id,
            clusters: [
                FaceClusterInput(
                    label: "A",
                    members: [
                        FaceClusterMemberInput(
                            photoId: photoIds[0], photoPath: "/shoot/a.jpg",
                            bbox: [0.1, 0.1, 0.3, 0.3], confidence: 0.9
                        ),
                        FaceClusterMemberInput(
                            photoId: photoIds[1], photoPath: "/shoot/b.jpg",
                            bbox: [0.2, 0.2, 0.4, 0.4], confidence: 0.8
                        ),
                    ]
                ),
                FaceClusterInput(
                    label: "B",
                    members: [
                        FaceClusterMemberInput(
                            photoId: photoIds[2], photoPath: "/shoot/c.jpg",
                            bbox: [0.3, 0.3, 0.5, 0.5], confidence: 0.7
                        )
                    ]
                ),
            ]
        )
        self.db = db
        self.sessionId = session.id
        self.photoIds = photoIds
        self.faceRepo = faceRepo
        self.jobService = jobService
        self.clusters = clusters
        self.faceAPI = LiveFaceAPI(
            faceKwService: faceKwService,
            jobService: jobService,
            settingsService: settingsService
        )
    }

    func job(_ jobId: String) throws -> AnalysisJobData? {
        try jobService.list().first { $0.id == jobId }
    }
}

private func faceGatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

@Suite("R1 P1-2 Live Face API")
struct APIFaceBehaviorTests {
    @Test("merge：源簇成员并入目标簇、源簇消失；不存在的簇报 FKW_CLUSTER_NOT_FOUND")
    func mergeMovesMembers() async throws {
        let fixture = try FaceBehaviorFixture()
        let source = try #require(fixture.clusters.first)
        let target = try #require(fixture.clusters.last)
        #expect(source != target)

        try await fixture.faceAPI.merge(
            FaceMergeInput(
                sessionId: fixture.sessionId,
                source: Int(source),
                target: Int(target)
            )
        )

        let clusters = try await fixture.faceAPI.clusters(fixture.sessionId)
        #expect(clusters.count == 1)
        let merged = try #require(clusters.first)
        #expect(merged.id == Int(target))
        #expect(merged.size == 3)
        #expect(
            Set(merged.members.map(\.photoId))
                == Set(fixture.photoIds.prefix(3))
        )

        let missing = await faceGatherError {
            try await fixture.faceAPI.merge(
                FaceMergeInput(
                    sessionId: fixture.sessionId,
                    source: 999_999,
                    target: Int(target)
                )
            )
        }
        #expect(missing?.code == .FKW_CLUSTER_NOT_FOUND)
    }

    @Test("removeMember：成员清单收敛、缺失成员显式失败、移除最后成员后簇行删除")
    func removeMemberShrinksCluster() async throws {
        let fixture = try FaceBehaviorFixture()
        let cluster = try #require(
            try await fixture.faceAPI.clusters(fixture.sessionId).first { $0.size == 2 }
        )
        let removed = try #require(cluster.members.first)
        let surviving = try #require(cluster.members.first { $0.memberId != removed.memberId })

        try await fixture.faceAPI.removeMember(
            FaceRemoveMemberInput(
                sessionId: fixture.sessionId,
                clusterId: cluster.id,
                memberId: removed.memberId
            )
        )
        let after = try #require(
            try await fixture.faceAPI.clusters(fixture.sessionId).first { $0.id == cluster.id }
        )
        #expect(after.size == 1)
        #expect(after.members.map(\.memberId) == [surviving.memberId])

        let missing = await faceGatherError {
            try await fixture.faceAPI.removeMember(
                FaceRemoveMemberInput(
                    sessionId: fixture.sessionId,
                    clusterId: cluster.id,
                    memberId: removed.memberId
                )
            )
        }
        #expect(missing?.code == .FKW_CLUSTER_MEMBER_NOT_FOUND)

        // 无绑定的簇在最后一个成员移除后被 faceRepo 物理删除。
        let last = try #require(after.members.first)
        try await fixture.faceAPI.removeMember(
            FaceRemoveMemberInput(
                sessionId: fixture.sessionId,
                clusterId: cluster.id,
                memberId: last.memberId
            )
        )
        let remaining = try await fixture.faceAPI.clusters(fixture.sessionId)
        #expect(!remaining.contains { $0.id == cluster.id })
    }

    @Test("cancelAnalysis：只取消本会话 faceAnalyze job；空白 sessionId 显式失败")
    func cancelAnalysisScopesJobs() async throws {
        let fixture = try FaceBehaviorFixture()
        let target = try fixture.jobService.create(JobCreateParams(
            type: .faceAnalyze,
            scopeType: "session",
            scopeId: fixture.sessionId,
            dedupeKey: "face.analyze:cancel-target"
        ))
        let otherSession = try fixture.jobService.create(JobCreateParams(
            type: .faceAnalyze,
            scopeType: "session",
            scopeId: "other-session",
            dedupeKey: "face.analyze:cancel-other"
        ))
        let otherType = try fixture.jobService.create(JobCreateParams(
            type: .similarityAnalyze,
            scopeType: "session",
            scopeId: fixture.sessionId,
            dedupeKey: "similarity.analyze:cancel-other-type"
        ))

        try await fixture.faceAPI.cancelAnalysis(fixture.sessionId)

        #expect(try fixture.job(target.id)?.status == .cancelled)
        #expect(try fixture.job(otherSession.id)?.status == .queued)
        #expect(try fixture.job(otherType.id)?.status == .queued)

        let blank = await faceGatherError {
            try await fixture.faceAPI.cancelAnalysis("   ")
        }
        #expect(blank?.code == .INVALID_PARAM)
        #expect(blank?.params["field"] == "sessionId")
    }
}
