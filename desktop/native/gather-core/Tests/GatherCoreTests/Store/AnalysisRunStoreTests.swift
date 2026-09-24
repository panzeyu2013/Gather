// Tests/GatherCoreTests/Store/AnalysisRunStoreTests.swift
// W2c Store 测试：JobStore.insertAnalysisRun / finishAnalysisRun / latestAnalysisRun
// （原 Services/SimilarityService.swift 753-780 行 startAnalysisRun/finalizeAnalysisRun
// 的 SQL 下沉；latest 读取语义见方法注释）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/AnalysisRunStore (W2c)")
struct AnalysisRunStoreTests {
    private func makeStore() async throws -> (store: SQLiteJobStore, database: SQLiteDatabase) {
        let database = try await makeMigratedStore(path: storeTempPath("analysis-run"))
        try await insertSession(database, "s1")
        return (SQLiteJobStore(database: database), database)
    }

    @Test("insertAnalysisRun：返回自增 runId；status=running / finished_at 空 / params 保留")
    func insertRun() async throws {
        let (store, _) = try await makeStore()
        let first = try await store.insertAnalysisRun(AnalysisRunInsert(
            sessionId: "s1", kind: "similarity", photoCount: 3, indexSeq: 7,
            params: #"{"threshold":8,"minGroupSize":2}"#
        ))
        let second = try await store.insertAnalysisRun(AnalysisRunInsert(
            sessionId: "s1", kind: "similarity", photoCount: 5, indexSeq: 9,
            params: "{}"
        ))
        #expect(first > 0)
        #expect(second > first, "AUTOINCREMENT runId 递增")

        let record = try #require(try await store.latestAnalysisRun(sessionId: "s1", kind: "similarity"))
        #expect(record.id == second)
        #expect(record.sessionId == "s1")
        #expect(record.kind == "similarity")
        #expect(record.photoCount == 5)
        #expect(record.indexSeq == 9)
        #expect(!record.startedAt.isEmpty, "started_at 必须落库")
        #expect(record.finishedAt == "", "未完成 run 的 finished_at 为空串（旧写入逐字）")
        #expect(record.status == "running")
        #expect(record.params == "{}")
    }

    @Test("finishAnalysisRun：写 status/finished_at；未知 runId 返回 false")
    func finishRun() async throws {
        let (store, _) = try await makeStore()
        let runId = try await store.insertAnalysisRun(AnalysisRunInsert(
            sessionId: "s1", kind: "similarity", photoCount: 1, indexSeq: 1, params: "{}"
        ))
        #expect(try await store.finishAnalysisRun(runId: runId, status: "ok"))
        let record = try #require(try await store.latestAnalysisRun(sessionId: "s1", kind: "similarity"))
        #expect(record.status == "ok")
        #expect(!record.finishedAt.isEmpty, "终态必须写 finished_at")
        #expect(try await store.finishAnalysisRun(runId: 999_999, status: "failed") == false)
    }

    @Test("latestAnalysisRun：kind/session 隔离、无行 nil；不过滤 status（failed 也返回最新）")
    func latestRunSemantics() async throws {
        let (store, _) = try await makeStore()
        let olderOk = try await store.insertAnalysisRun(AnalysisRunInsert(
            sessionId: "s1", kind: "similarity", photoCount: 2, indexSeq: 2, params: "{}"
        ))
        _ = try await store.finishAnalysisRun(runId: olderOk, status: "ok")
        let newerFailed = try await store.insertAnalysisRun(AnalysisRunInsert(
            sessionId: "s1", kind: "similarity", photoCount: 3, indexSeq: 3, params: "{}"
        ))
        _ = try await store.finishAnalysisRun(runId: newerFailed, status: "failed")
        let faceRun = try await store.insertAnalysisRun(AnalysisRunInsert(
            sessionId: "s1", kind: "face", photoCount: 4, indexSeq: 4, params: "{}"
        ))

        let latest = try #require(try await store.latestAnalysisRun(sessionId: "s1", kind: "similarity"))
        #expect(latest.id == newerFailed, "ORDER BY id DESC：最新行优先")
        #expect(latest.status == "failed", "不过滤 status（ok 过滤由 WorkspaceStore.latestOkRun 负责）")
        #expect(try await store.latestAnalysisRun(sessionId: "s1", kind: "face")?.id == faceRun)
        #expect(try await store.latestAnalysisRun(sessionId: "s1", kind: "quality") == nil)
        #expect(try await store.latestAnalysisRun(sessionId: "ghost", kind: "similarity") == nil)
    }
}
