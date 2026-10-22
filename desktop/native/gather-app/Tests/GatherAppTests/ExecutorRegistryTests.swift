// desktop/native/gather-app/Tests/GatherAppTests/ExecutorRegistryTests.swift
// Cut 1 / B8.3a：ExecutorRegistry 的注册/执行契约。
//
// 覆盖：
// 1. register 返回并实际注册全部 8 个 AnalysisJobType；JobService 能把每种
//    type 的 job 交给对应 executor（未注册会永远停在 queued）；
// 2. 成功路径：quality.score / checksum.backfill / thumbnail.build /
//    duplicate.scan 在空会话上成功；export.execute 空会话成功并落 checkpoint；
// 3. 失败路径：similarity.analyze（SIM_NO_PHOTOS）、face.analyze（SESSION_NOT_FOUND）、
//    metadata.scan（SESSION_NOT_FOUND）、export.execute（EXPORT_ALL_FAILED）。
//
// 夹具使用真实 GatherCore 服务 + 内存 SQLite，只把文件系统内容降到空会话/
// 缺失源文件；不引用已删除的命令面，验证注册入口与开工路径共用同一套闭包。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

// MARK: - 装配夹具

/// 不触碰文件系统的 XMPProvider（metadata.scan 的依赖构造需要，但空会话不读写）。
private struct RegistryNoopXMP: XMPProvider {
    func readKeywords(photoPath: String) async throws -> [String] { [] }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { MetadataWriteAttributes() }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

/// MetadataMutationPort 的空实现（metadata.scan 空会话不会排队任何写入）。
private struct RegistryNoopMutations: MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [], revision: 1, status: "pending")
    }

    func queueMutation(
        sessionId: String, photoId: String, patch: MetadataPatch, source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [], revision: 1, status: "pending")
    }
}

private struct ExecutorRegistryFixture {
    let root: URL
    let exportRoot: URL
    let db: DBConnection
    let sessionId: String
    let jobService: JobService
    let registeredTypes: [AnalysisJobType]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-executor-registry-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let assetRepo = AssetRepo(connection: db)
        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        let session = try sessionRepo.create(name: "B8.3a", source: "test")

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
                xmp: RegistryNoopXMP(),
                connection: db,
                mutations: RegistryNoopMutations()
            ),
            photoRepo: photoRepo,
            assetRepo: assetRepo,
            imagePreloadService: ImagePreloadService(),
            exportService: ExportService(photoRepo: photoRepo, sessionRepo: sessionRepo, connection: db)
        )

        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        self.root = root
        self.exportRoot = exportRoot
        self.db = db
        self.sessionId = session.id
        self.jobService = jobService
        self.registeredTypes = ExecutorRegistry.register(jobService: jobService, deps: deps)
        jobService.start()
    }

    func cleanup() {
        db.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func withRegistryFixture(
    _ body: (ExecutorRegistryFixture) async throws -> Void
) async throws {
    let fixture = try ExecutorRegistryFixture()
    do {
        try await body(fixture)
        await fixture.jobService.stop()
        fixture.cleanup()
    } catch {
        await fixture.jobService.stop()
        fixture.cleanup()
        throw error
    }
}

private func createJob(
    _ jobService: JobService,
    type: AnalysisJobType,
    sessionId: String,
    checkpoint: [String: JSONValue]? = nil
) throws -> AnalysisJobData {
    try jobService.create(JobCreateParams(
        type: type,
        scopeType: "session",
        scopeId: sessionId,
        dedupeKey: "b8.3a:\(type.rawValue):\(sessionId)",
        checkpoint: checkpoint
    ))
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

private func seedMissingSourcePhoto(_ fixture: ExecutorRegistryFixture, photoId: String) throws {
    let path = fixture.root.appendingPathComponent("\(photoId).jpg").path
    let now = "2026-01-01T00:00:00.000Z"
    _ = try fixture.db.prepare("""
        INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
      """).run([
        .text("af-\(photoId)"), .text(path), .text("\(photoId).jpg"), .text(now), .text(now),
    ])
    _ = try fixture.db.prepare("""
        INSERT INTO photos (
          id, session_id, filepath, filename, asset_file_id, width, height,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 100, 80, ?, ?)
      """).run([
        .text(photoId), .text(fixture.sessionId), .text(path), .text("\(photoId).jpg"),
        .text("af-\(photoId)"), .text(now), .text(now),
      ])
}

// MARK: - 用例

@Suite("B8.3a ExecutorRegistry")
struct ExecutorRegistryTests {
    @Test("register：8 个 type 全部注册，JobService 逐 type 执行")
    func registersAllEightExecutors() async throws {
        try await withRegistryFixture { fixture in
            #expect(fixture.registeredTypes.count == 8)
            #expect(Set(fixture.registeredTypes) == Set(AnalysisJobType.allCases))

            // 未知会话：已注册的 executor 会被调度并落到终态；未注册则永远 queued。
            // 期望终态同时记录每类 executor 的缺省行为（成功/失败都算「执行过」）。
            let expected: [AnalysisJobType: AnalysisJobStatus] = [
                .similarityAnalyze: .failed, // SIM_NO_PHOTOS（无照片）
                .duplicateScan: .succeeded, // 空会话扫描
                .faceAnalyze: .failed, // SESSION_NOT_FOUND
                .qualityScore: .succeeded, // 空照片集合
                .metadataScan: .failed, // SESSION_NOT_FOUND
                .checksumBackfill: .succeeded, // 0 条待回填
                .thumbnailBuild: .succeeded, // 空 paths
                .exportExecute: .failed, // checkpoint 缺 options → 解码失败
            ]

            for type in AnalysisJobType.allCases {
                let job = try createJob(
                    fixture.jobService, type: type, sessionId: "missing-\(type.rawValue)")
                let terminal = try await waitForTerminal(fixture.jobService, jobId: job.id)
                #expect(terminal != nil, "\(type.rawValue) 未被 JobService 执行（可能未注册）")
                #expect(
                    terminal?.status == expected[type],
                    "\(type.rawValue) 终态异常：\(String(describing: terminal?.status))"
                )
            }
        }
    }

    @Test("export.execute：空会话成功并落交付摘要")
    func exportExecuteSucceedsOnEmptySession() async throws {
        try await withRegistryFixture { fixture in
            let options = ExportOptions(
                scope: .session,
                format: .original,
                naming: ExportNaming(pattern: "{original}"),
                includeXmp: false,
                destination: fixture.exportRoot.path
            )
            let job = try createJob(
                fixture.jobService,
                type: .exportExecute,
                sessionId: fixture.sessionId,
                checkpoint: ["options": try JSONValue(from: options)]
            )
            let terminal = try await waitForTerminal(fixture.jobService, jobId: job.id)

            #expect(terminal?.status == .succeeded)
            #expect(terminal?.checkpoint["exported"]?.numberValue == 0)
            #expect(terminal?.checkpoint["failed"]?.numberValue == 0)
            #expect(terminal?.checkpoint["totalFiles"]?.numberValue == 0)
        }
    }

    @Test("export.execute：源文件全缺失 → job failed（EXPORT_ALL_FAILED）")
    func exportExecuteFailsWhenEveryFileFails() async throws {
        try await withRegistryFixture { fixture in
            try seedMissingSourcePhoto(fixture, photoId: "missing-1")

            let options = ExportOptions(
                scope: .session,
                format: .original,
                naming: ExportNaming(pattern: "{original}"),
                includeXmp: false,
                destination: fixture.exportRoot.path
            )
            let job = try createJob(
                fixture.jobService,
                type: .exportExecute,
                sessionId: fixture.sessionId,
                checkpoint: ["options": try JSONValue(from: options)]
            )
            let terminal = try await waitForTerminal(fixture.jobService, jobId: job.id)

            #expect(terminal?.status == .failed)
            #expect(terminal?.errorCode == "EXPORT_ALL_FAILED")
            #expect(terminal?.checkpoint["exported"]?.numberValue == 0)
            #expect((terminal?.checkpoint["failed"]?.numberValue ?? 0) >= 1)
        }
    }

    @Test("metadata.scan：空目录成功（checkpoint 落 result）")
    func metadataScanSucceedsOnEmptyDirectory() async throws {
        try await withRegistryFixture { fixture in
            let job = try createJob(
                fixture.jobService,
                type: .metadataScan,
                sessionId: fixture.sessionId,
                checkpoint: ["requestedPaths": .array([.string(fixture.exportRoot.path)])]
            )
            let terminal = try await waitForTerminal(fixture.jobService, jobId: job.id)

            #expect(terminal?.status == .succeeded)
            #expect(terminal?.checkpoint["result"] != nil)
        }
    }
}
