// Tests/GatherCoreTests/API/JobsCommandsImplTests.swift
// R5：jobs 域命令实现直测（批次 B2）。
// 覆盖旧路由分支语义：list 全量/状态过滤、cancel/retry 布尔结果、
// clear_completed 的 confirmed 门控与阶段证据排除。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/JobsCommandsImpl (R5)")
struct JobsCommandsImplTests {
    /// 目录直连 harness：命令实现与 Store 共享同一临时库；不 start 运行器，
    /// 行状态由 Store 直写，只验命令边界。
    private func makeHarness() async throws -> (impl: JobsCommandsImpl, store: SQLiteJobStore, db: SQLiteDatabase, path: String) {
        let path = storeTempPath("jobs-commands")
        let db = try await makeMigratedStore(path: path)
        let store = SQLiteJobStore(database: db)
        let runner = JobRunner(jobStore: store, leaseOwner: "jobs-commands-test")
        return (JobsCommandsImpl(jobs: runner), store, db, path)
    }

    private func createJob(
        _ store: SQLiteJobStore,
        type: AnalysisJobType = .similarityAnalyze,
        scopeId: String = "s1"
    ) async throws -> AnalysisJobData {
        try await store.create(JobCreateParams(
            type: type,
            scopeType: "session",
            scopeId: scopeId,
            dedupeKey: "\(type.rawValue):\(scopeId)"
        ))
    }

    @Test("list returns all jobs by default and filters by status when provided")
    func listAllAndFiltered() async throws {
        let (impl, store, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let first = try await createJob(store, scopeId: "s1")
        let second = try await createJob(store, type: .faceAnalyze, scopeId: "s2")
        #expect(try await impl.cancel(JobCancelParams(jobId: second.id)))

        let all = try await impl.list(JobListParams())
        #expect(Set(all.map(\.id)) == Set([first.id, second.id]))

        let cancelled = try await impl.list(JobListParams(status: .cancelled))
        #expect(cancelled.map(\.id) == [second.id])
        #expect(cancelled.first?.status == .cancelled)
    }

    @Test("cancel returns true once and false for an already terminal job")
    func cancelSemantics() async throws {
        let (impl, store, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let job = try await createJob(store)

        #expect(try await impl.cancel(JobCancelParams(jobId: job.id)) == true)
        #expect(try await impl.cancel(JobCancelParams(jobId: job.id)) == false)
        #expect(try await store.get(job.id)?.status == .cancelled)
    }

    @Test("retry requeues a cancelled job and rejects a fresh queued job")
    func retrySemantics() async throws {
        let (impl, store, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let job = try await createJob(store)
        #expect(try await impl.cancel(JobCancelParams(jobId: job.id)) == true)

        #expect(try await impl.retry(JobRetryParams(jobId: job.id)) == true)
        #expect(try await store.get(job.id)?.status == .queued)
        #expect(try await impl.retry(JobRetryParams(jobId: job.id)) == false)
    }

    @Test("clearCompleted requires confirmation and keeps stage evidence jobs")
    func clearCompletedGateAndExclusion() async throws {
        let (impl, store, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let analysis = try await createJob(store, scopeId: "s1")
        let scan = try await createJob(store, type: .metadataScan, scopeId: "s1")
        _ = try await db.run(
            "UPDATE analysis_jobs SET status = 'succeeded' WHERE id IN (?, ?)",
            [.text(analysis.id), .text(scan.id)]
        )

        await #expect(throws: JobsCommandsError.clearConfirmRequired) {
            try await impl.clearCompleted(JobClearCompletedParams(confirmed: false))
        }
        #expect(try await impl.clearCompleted(JobClearCompletedParams(confirmed: true)) == 1)
        let remaining = try await store.list()
        #expect(remaining.map(\.id) == [scan.id])
    }
}
