// desktop/native/gather-app/Tests/GatherAppTests/APISimilarityTests.swift
// R1 P1-2：此前只有 Stub 接线、没有 Live 行为测试的 SimilarityAPI.cancelAnalysis。
//
// 覆盖：返回值 true、jobService.cancelScope(.similarityAnalyze) 的会话/类型
// 收窄（其它会话与其它类型的 job 不受影响）、裸 sessionId 的 INVALID_PARAM。
// 服务层 abort 只在有在飞占用槽时才有可观察副作用，这里不构造假推理；任务
// 取消是本方法唯一可在无模型环境稳定断言的行为。
//
// 夹具：内存 SchemaV1 库 + 真实 SimilarityService / JobService，独立建库，
// 不 start() JobService（queued 取消不需要调度器），无全局状态。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

private struct SimilarityBehaviorFixture {
    let db: DBConnection
    let sessionId: String
    let jobService: JobService
    let similarityAPI: LiveSimilarityAPI

    init() throws {
        let db = try makeGatherTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "R1P1-2 Sim", source: "test")
        let photoRepo = PhotoRepo(connection: db)
        _ = try photoRepo.addPhotos(
            sessionId: session.id,
            filepaths: [
                PhotoAddInput(filepath: "/shoot/a.jpg", width: 100, height: 100),
                PhotoAddInput(filepath: "/shoot/b.jpg", width: 100, height: 100),
            ],
            "test"
        )
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let similarityService = SimilarityService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            similarityResultRepo: SimilarityResultRepo(connection: db),
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            }
        )
        self.db = db
        self.sessionId = session.id
        self.jobService = jobService
        self.similarityAPI = LiveSimilarityAPI(
            similarityService: similarityService,
            jobService: jobService,
            settingsService: settingsService
        )
    }

    func job(_ jobId: String) throws -> AnalysisJobData? {
        try jobService.list().first { $0.id == jobId }
    }
}

private func similarityGatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

@Suite("R1 P1-2 Live Similarity API")
struct APISimilarityBehaviorTests {
    @Test("cancelAnalysis：返回 true，只取消本会话 similarityAnalyze job；空白 sessionId 显式失败")
    func cancelAnalysisScopesJobs() async throws {
        let fixture = try SimilarityBehaviorFixture()
        let target = try fixture.jobService.create(JobCreateParams(
            type: .similarityAnalyze,
            scopeType: "session",
            scopeId: fixture.sessionId,
            dedupeKey: "similarity.analyze:cancel-target"
        ))
        let otherSession = try fixture.jobService.create(JobCreateParams(
            type: .similarityAnalyze,
            scopeType: "session",
            scopeId: "other-session",
            dedupeKey: "similarity.analyze:cancel-other"
        ))
        let otherType = try fixture.jobService.create(JobCreateParams(
            type: .faceAnalyze,
            scopeType: "session",
            scopeId: fixture.sessionId,
            dedupeKey: "face.analyze:cancel-other-type"
        ))

        let cancelled = try await fixture.similarityAPI.cancelAnalysis(fixture.sessionId)
        #expect(cancelled)
        #expect(try fixture.job(target.id)?.status == .cancelled)
        #expect(try fixture.job(otherSession.id)?.status == .queued)
        #expect(try fixture.job(otherType.id)?.status == .queued)

        let blank = await similarityGatherError {
            try await fixture.similarityAPI.cancelAnalysis("\n\t")
        }
        #expect(blank?.code == .INVALID_PARAM)
        #expect(blank?.params["field"] == "sessionId")
    }
}
