// desktop/native/gather-app/Tests/GatherAppTests/AppRuntimeTests.swift
// Cut 1 / B8.3b-1：AppRuntime 生命周期契约。
//
// 覆盖：
// 1. start()：注册全部 8 个 AnalysisJobType 并真正启动 JobService 调度器
//    （入队 thumbnail.build 能跑到 succeeded，未注册/未启动会永远 queued）；
// 2. shutdown()：关闭 SQLite，重复调用幂等；
// 3. recordReloadAck(sessionId:)：写入 sessions.reload_acked_at；
// 4. start → shutdown → start：抛 AppRuntimeError.alreadyShutDown（失败可见）；
// 5. 组合根：AppServices 与 runtime 共用同一 db/jobService；
//    reload ack 由 runtime 直接写库，停机由 runtime.shutdown 完成
//    （S5c-2b-3b-2b-1 起 runtime 不再持有/排空 MetadataSyncCoordinator）。
//
// 夹具只构造真实 GatherCore 服务 + 内存 SQLite，不引用字符串命令面（B8.3b-2b 起
// 生产路径已无字符串命令面），保证 start() 的注册/启动可独立观测。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery
@testable import GatherUI
@testable import GatherHost

// MARK: - 夹具依赖（空实现只用于不触碰文件系统的用例）

private struct RuntimeNoopXMP: XMPProvider {
    func readKeywords(photoPath: String) async throws -> [String] { [] }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { MetadataWriteAttributes() }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

private struct RuntimeNoopMutations: MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [],
            revision: 1, status: "pending")
    }

    func queueMutation(
        sessionId: String, photoId: String, patch: MetadataPatch, source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [],
            revision: 1, status: "pending")
    }
}

// MARK: - 装配夹具

private struct AppRuntimeFixture {
    let db: DBConnection
    let jobService: JobService
    let sessionRepo: SessionRepo
    let runtime: AppRuntime

    init() throws {
        let db = try makeGatherTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let assetRepo = AssetRepo(connection: db)
        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        let deps = ExecutorRegistry.Dependencies(
            similarityService: SimilarityService(
                photoRepo: photoRepo,
                sessionRepo: sessionRepo,
                similarityResultRepo: SimilarityResultRepo(connection: db),
                clusterStateRepo: SimilarityClusterStateRepo(connection: db),
                connection: db
            ),
            duplicateService: DuplicateService(connection: db),
            faceKwService: FaceKwService(
                photoRepo: photoRepo,
                sessionRepo: sessionRepo,
                faceRepo: faceRepo,
                personRepo: personRepo,
                connection: db
            ),
            qualityService: QualityService(photoRepo: photoRepo, connection: db),
            indexerService: IndexerService(
                connection: db,
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                assetRepo: assetRepo,
                faceRepo: faceRepo
            ),
            metadataService: MetadataService(
                metadataCacheRepo: MetadataCacheRepo(connection: db),
                xmp: RuntimeNoopXMP(),
                connection: db,
                mutations: RuntimeNoopMutations()
            ),
            photoRepo: photoRepo,
            assetRepo: assetRepo,
            imagePreloadService: ImagePreloadService(),
            exportService: ExportService(photoRepo: photoRepo, sessionRepo: sessionRepo, connection: db)
        )
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        self.db = db
        self.jobService = jobService
        self.sessionRepo = sessionRepo
        self.runtime = AppRuntime(
            db: db,
            jobService: jobService,
            delivery: DeliveryCoordinator(connection: db, xmp: RuntimeNoopXMP()),
            executorDeps: deps
        )
    }
}

/// 夹具统一收尾：无论断言/抛错都走一次 shutdown（幂等，重复调用无副作用）。
private func withAppRuntimeFixture(
    _ body: (AppRuntimeFixture) async throws -> Void
) async throws {
    let fixture = try AppRuntimeFixture()
    do {
        try await body(fixture)
        await fixture.runtime.shutdown()
    } catch {
        await fixture.runtime.shutdown()
        throw error
    }
}

private func intentCount(_ db: DBConnection) throws -> Int {
    Int(try db.prepare("SELECT COUNT(*) FROM delivery_intents").get()?[0].intValue ?? -1)
}

private func waitForTerminal(
    _ jobService: JobService,
    jobId: String,
    timeout: TimeInterval = 15
) async throws -> AnalysisJobData? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let job = try jobService.list(includeCheckpoint: true).first(where: { $0.id == jobId }),
           job.status == .succeeded || job.status == .failed || job.status == .cancelled {
            return job
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

// MARK: - 用例

@Suite("B8.3b-1 AppRuntime")
struct AppRuntimeTests {
    @Test("start：注册 8 个 executor 并启动 JobService")
    func startRegistersAllExecutorsAndStartsScheduler() async throws {
        try await withAppRuntimeFixture { fixture in
            let types = try fixture.runtime.start()
            #expect(types.count == 8)
            #expect(Set(types) == Set(AnalysisJobType.allCases))

            // 未注册 executor 或未启动调度器时，job 会永远停在 queued。
            let job = try fixture.jobService.create(JobCreateParams(
                type: .thumbnailBuild,
                scopeType: "session",
                scopeId: "runtime-start",
                dedupeKey: "b8.3b-1:thumbnail:\(UUID().uuidString)",
                checkpoint: ["paths": .array([]), "size": .number(256)]
            ))
            let terminal = try await waitForTerminal(fixture.jobService, jobId: job.id)
            #expect(terminal?.status == .succeeded)
        }
    }

    @Test("shutdown：关闭 SQLite，并发/重复调用幂等")
    func shutdownClosesDatabaseAndIsIdempotent() async throws {
        try await withAppRuntimeFixture { fixture in
            _ = try fixture.runtime.start()

            // 并发调用共享同一个停机 Task：只 stop/shutdown/close 一次。
            // 先取出 Sendable 的 runtime，避免把非 Sendable 的测试夹具送进 async let。
            let runtime = fixture.runtime
            async let first: Void = runtime.shutdown()
            async let second: Void = runtime.shutdown()
            _ = await (first, second)
            #expect(fixture.db.isClosed)

            // 完成后的重复调用必须直接返回，不重复 stop/close、不崩。
            await fixture.runtime.shutdown()
            #expect(fixture.db.isClosed)
        }
    }

    @Test("start：jobService.start 之后回放 delivery_intents（applied 终态被清扫）")
    func startReplaysDeliveryIntents() async throws {
        try await withAppRuntimeFixture { fixture in
            // applied 是 replayAll() 的确定性清扫对象：不需要真实文件阶段即可验证
            // 「start 触发了回放」。
            _ = try fixture.db.prepare("""
                INSERT INTO delivery_intents (kind, xmp_path, phase, payload_json, created_at, updated_at)
                VALUES ('cleanup', '/shoot/p1.xmp', 'applied', '{}',
                        '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run()
            #expect(try intentCount(fixture.db) == 1)

            _ = try fixture.runtime.start()
            await fixture.runtime.waitForDeliveryReplay()

            #expect(try intentCount(fixture.db) == 0, "启动回放必须清扫 applied intent")
            #expect(fixture.runtime.deliveryReplayFailure == nil)
        }
    }

    @Test("recordReloadAck：写入 sessions.reload_acked_at")
    func recordReloadAckWritesDatabase() async throws {
        try await withAppRuntimeFixture { fixture in
            let session = try fixture.sessionRepo.create(name: "runtime-ack", source: "test")
            #expect(session.reloadAckedAt == nil)

            try fixture.runtime.recordReloadAck(sessionId: session.id)

            let updated = try #require(try fixture.sessionRepo.get(id: session.id))
            let ack = try #require(updated.reloadAckedAt)
            #expect(!ack.isEmpty)
            #expect(ack.hasSuffix("Z"))
        }
    }

    @Test("start-shutdown-start：失败可见（alreadyShutDown）")
    func startAfterShutdownFails() async throws {
        try await withAppRuntimeFixture { fixture in
            _ = try fixture.runtime.start()
            await fixture.runtime.shutdown()

            do {
                _ = try fixture.runtime.start()
                Issue.record("shutdown 后再次 start 应抛 AppRuntimeError.alreadyShutDown")
            } catch let error as AppRuntimeError {
                #expect(error == .alreadyShutDown)
            } catch {
                Issue.record("意外错误类型：\(error)")
            }
        }
    }

    @Test("组合根：AppServices 与 runtime 共用实例，runtime 写库/停机")
    func appServicesAndRuntimeShareComposition() async throws {
        let db = try makeGatherTestDB()
        let composition = AppComposition.make(db: db)
        let runtime = composition.runtime
        do {
            #expect(runtime.db === db)
            #expect(runtime.jobService === composition.jobService)

            let services = AppServices.live(composition: composition)
            #expect(services.runtime === runtime)

            let session = try SessionRepo(connection: db).create(name: "runtime-delegate", source: "test")
            try runtime.recordReloadAck(sessionId: session.id)
            #expect(try SessionRepo(connection: db).get(id: session.id)?.reloadAckedAt != nil)

            _ = try runtime.start()
            await runtime.shutdown()
            #expect(db.isClosed)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

}
