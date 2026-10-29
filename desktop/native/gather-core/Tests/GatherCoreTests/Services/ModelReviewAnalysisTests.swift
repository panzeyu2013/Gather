// desktop/native/gather-core/Tests/GatherCoreTests/Services/ModelReviewAnalysisTests.swift
// 模型级初审的编排面（ModelReviewService.analyze）：缓存复用、失败不落库、
// 分批进度、照片子集、取消与空会话。
//
// 刻意不触达 Vision：previewProvider 注入「直接抛错 / 命中缓存」两条路径，
// 失败行在解码前返回，真实人脸/审美推理仍只在夜间 GATHER_MODEL_TESTS 覆盖。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("模型级初审编排（缓存/失败/批次）")
struct ModelReviewAnalysisTests {
    private struct Calls { var count = 0 }
    private struct Progress { var entries: [(Int, Int)] = [] }

    private struct Fixture {
        let db: DBConnection
        let service: ModelReviewService
        let repo: ModelReviewRepo
        let previewCalls: LockedBox<Calls>
    }

    private func makeFixture(
        photoIds: [String],
        preview: @escaping @Sendable (String) async throws -> Data = { _ in
            throw NSError(domain: "ModelReviewTests", code: 1)
        }
    ) throws -> Fixture {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        for (index, id) in photoIds.enumerated() {
            let assetFileId = "af-\(id)"
            try insertAssetFile(db, id: assetFileId, normalizedPath: "/vault/\(id).CR3")
            try insertPhoto(db, id: id, sessionId: "s1")
            _ = try db.prepare("UPDATE photos SET asset_file_id = ? WHERE id = ?")
                .run([.text(assetFileId), .text(id)])
            _ = index
        }
        let repo = ModelReviewRepo(connection: db)
        let calls = LockedBox(Calls())
        let service = ModelReviewService(
            photoRepo: PhotoRepo(connection: db),
            modelReviewRepo: repo,
            faceBoxes: { _, _ in [] },
            previewProvider: { path, _ in
                calls.lock.withLock { calls.count += 1 }
                return try await preview(path)
            },
            statProvider: { _ in (size: 0, mtimeMs: 0) }
        )
        return Fixture(db: db, service: service, repo: repo, previewCalls: calls)
    }

    @Test("空会话直接返回空数组，不取页也不写库")
    func emptySessionReturnsEmpty() async throws {
        let fixture = try makeFixture(photoIds: [])
        defer { fixture.db.close() }

        let results = try await fixture.service.analyze(sessionId: "s1")
        #expect(results.isEmpty)
        #expect(fixture.previewCalls.lock.withLock { fixture.previewCalls.count } == 0)
        #expect(try fixture.repo.latest(photoIds: ["p1"]).isEmpty)
    }

    @Test("解码失败：每张返回 failed 且不落库（避免瞬时失败永久缓存）")
    func failedAnalysisIsNotPersisted() async throws {
        let fixture = try makeFixture(photoIds: ["p1", "p2"])
        defer { fixture.db.close() }

        let results = try await fixture.service.analyze(sessionId: "s1")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.status == .failed })
        #expect(results.allSatisfy { $0.warnings == ["analysis_failed"] })
        #expect(results.allSatisfy { $0.errorMessage?.isEmpty == false })
        #expect(try fixture.repo.latest(photoIds: ["p1", "p2"]).isEmpty)
        #expect(fixture.previewCalls.lock.withLock { fixture.previewCalls.count } == 2)
    }

    @Test("指纹相同命中缓存：不重复解码；force 强制重算")
    func cachedResultIsReusedUnlessForced() async throws {
        let fixture = try makeFixture(photoIds: ["p1"])
        defer { fixture.db.close() }

        let fingerprint = ModelReviewService.fingerprint(
            faces: [], dimensions: (0, 0), contentKey: "")
        let cached = ModelReviewResult(
            photoId: "p1", assetFileId: "af-p1", status: .succeeded,
            eyesOpenScore: 0.8, warnings: [], modelId: ModelReviewService.modelId,
            modelVersion: ModelReviewService.modelVersion,
            inputFingerprint: fingerprint, updatedAt: "2026-01-01T00:00:00.000Z")
        let json = String(data: try JSONEncoder().encode(cached), encoding: .utf8) ?? "{}"
        try fixture.repo.insertResults(
            [ModelReviewInsert(
                photoId: "p1", assetFileId: "af-p1", resultJson: json,
                warningsJson: "[]", fingerprint: fingerprint,
                updatedAt: "2026-01-01T00:00:00.000Z")],
            modelId: ModelReviewService.modelId, modelVersion: ModelReviewService.modelVersion)

        let reused = try await fixture.service.analyze(sessionId: "s1")
        #expect(reused.count == 1)
        #expect(reused[0].status == .succeeded)
        #expect(reused[0].eyesOpenScore == 0.8)
        #expect(fixture.previewCalls.lock.withLock { fixture.previewCalls.count } == 0)

        let forced = try await fixture.service.analyze(sessionId: "s1", force: true)
        #expect(forced[0].status == .failed, "force 必须跳过缓存重新解码")
        #expect(fixture.previewCalls.lock.withLock { fixture.previewCalls.count } == 1)
        // 失败结果不覆盖已成功的缓存行；缓存命中会被重新落库（键序可能不同），
        // 按值比较而不是比较 JSON 文本。
        let stored = try #require(fixture.repo.latest(photoIds: ["p1"])["p1"]?.json)
        let decoded = try JSONDecoder().decode(ModelReviewResult.self, from: Data(stored.utf8))
        #expect(decoded == cached)
    }

    @Test("分批进度：5 张按 4 并发分批，回调 (4,5) 与 (5,5) 各一次")
    func reportsBatchedProgress() async throws {
        let fixture = try makeFixture(photoIds: (1...5).map { "p\($0)" })
        defer { fixture.db.close() }

        let progress = LockedBox(Progress())
        _ = try await fixture.service.analyze(
            sessionId: "s1", isCancelled: { false },
            onProgress: { done, total in
                progress.lock.withLock { progress.entries.append((done, total)) }
            })
        let observed = progress.lock.withLock { progress.entries }
        #expect(observed.count == 2)
        #expect(observed.first?.0 == 4 && observed.first?.1 == 5)
        #expect(observed.last?.0 == 5 && observed.last?.1 == 5)
    }

    @Test("photoIds 子集只分析指定照片；取消在首批前抛出")
    func subsetAndCancellation() async throws {
        let fixture = try makeFixture(photoIds: ["p1", "p2", "p3"])
        defer { fixture.db.close() }

        let subset = try await fixture.service.analyze(sessionId: "s1", photoIds: ["p2"])
        #expect(subset.map(\.photoId) == ["p2"])

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.service.analyze(
                sessionId: "s1", isCancelled: { true })
        }
    }
}
