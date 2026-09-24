// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Similarity/SimilarityRuntimeCancellationTests.swift
// W2c：SimilarityRuntime 取消 / flight 生命周期测试。
// - 承接旧 SimilarityServiceTests 取消 2 用例（占用保持到退出 / 无在飞 run 不翻转状态）；
// - 新增设计 §1.1 ⑤ 的 generation 守卫断言：
//   ① 首飞退出后后继 flight 才能进入，且后继终态不被首飞的迟到终态写覆写
//      （run 行逐条核对 failed → ok）；
//   ② catch 的终端状态写仍在飞时占用保持（迟到 catch 没有可覆写的窗口）。
//
// 所有对 analyze 任务的等待都走限时 tracker（SimRuntimeTaskTracker）：断言失败
// 而不是测试进程永久挂起。

import Foundation
import Testing
@testable import GatherCore

@Suite("SimilarityRuntime cancellation")
struct SimilarityRuntimeCancellationTests {
    @Test("keeps the session occupied until the cancelled analysis actually exits")
    func keepsOccupiedUntilExit() async throws {
        let gate = SimRuntimeGate()
        let harness = try await simRuntimeMakeHarness(thumbnail: { _, _ in
            await gate.wait()
            return simRuntimeUniformPixels
        })
        let runtime = harness.runtime
        let sessionId = harness.sessionId
        let firstTracker = SimRuntimeTaskTracker.track {
            try await runtime.analyze(sessionId: sessionId)
        }

        // 等分析进入解码窗口（run 行已写入）再取消。
        let runningSeen = await simRuntimeWaitForAnalysisRunStatus(harness, "running")
        #expect(runningSeen)
        try await runtime.cancel(sessionId: sessionId)
        let session = try await harness.sessionStore.get(id: sessionId)
        #expect(session?.analysisStatus == "cancelled")

        // 首跑仍在飞：再次 analyze 必须拒绝。
        await #expect(throws: SimilarityError.analysisRunning) {
            try await runtime.analyze(sessionId: sessionId)
        }

        await gate.release()
        #expect(await simRuntimeAwaitTracker(firstTracker) == .succeeded)

        // 早退路径：run 记录终态 failed（cancel 已写 cancelled），占用已释放。
        let cancelledRow = try await simRuntimeRunRow(harness.db, sessionId)
        let row = try #require(cancelledRow)
        #expect(row.text(at: 6) == "failed")
        #expect(try await harness.sessionStore.get(id: sessionId)?.analysisStatus == "cancelled")

        // A 退出后 B 可进入（同一会话，不必换 harness）：B 完整跑完，终态 done；
        // A 的迟到终态化只写自己的 run 行，绝不覆写 B 的状态。
        let successor = await simRuntimeRunOutcome {
            try await runtime.analyze(sessionId: sessionId)
        }
        #expect(successor == .succeeded)
        #expect(try await harness.sessionStore.get(id: sessionId)?.analysisStatus == "done")

        let runs = try await simRuntimeRunRecords(harness.db, sessionId)
        #expect(runs.map(\.status) == ["failed", "ok"])
        #expect(runs.allSatisfy { !$0.finishedAt.isEmpty })
    }

    @Test("cancel without an in-flight run does not flip the shared analysis status")
    func cancelWithoutRunKeepsStatus() async throws {
        let harness = try await simRuntimeMakeHarness()
        let session = try await harness.sessionStore.get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")

        try await harness.runtime.cancel(sessionId: harness.sessionId, markStatus: false)

        let after = try await harness.sessionStore.get(id: harness.sessionId)
        #expect(after?.analysisStatus == "idle")
    }
}

@Suite("SimilarityRuntime flight lifecycle")
struct SimilarityRuntimeFlightLifecycleTests {
    @Test("terminal catch write holds the flight so a late catch cannot overwrite the successor")
    func terminalCatchWriteHoldsFlight() async throws {
        let thumbnailGate = SimRuntimeGate()
        let harness = try await simRuntimeMakeHarness(
            thumbnail: { _, _ in
                await thumbnailGate.wait()
                return simRuntimeUniformPixels
            },
            sessionStoreWrap: { base in SimRuntimeStatusGateStore(base: base) }
        )
        let statusStore = harness.sessionStore as! SimRuntimeStatusGateStore
        let runtime = harness.runtime
        let sessionId = harness.sessionId
        let firstTracker = SimRuntimeTaskTracker.track {
            try await runtime.analyze(sessionId: sessionId)
        }
        #expect(await simRuntimeWaitForSessionStatus(harness, "running"))

        // 武装一次性闸门：下一次 updateAnalysisStatus（终端 done 写）挂起；
        // 放行时该次调用抛错（模拟终端状态写失败 → 触发 analyze 的 catch 路径）。
        await statusStore.armOnce(error: SimRuntimeTerminalWriteBoom())
        await thumbnailGate.release()
        #expect(await simRuntimeWaitUntil { await statusStore.totalParkedCalls == 1 })

        // 首飞主结果已保存，但终端状态写仍挂起（flight 未释放）：取消后后继被拒。
        try await runtime.cancel(sessionId: sessionId)
        #expect(try await harness.sessionStore.get(id: sessionId)?.analysisStatus == "cancelled")
        await #expect(throws: SimilarityError.analysisRunning) {
            try await runtime.analyze(sessionId: sessionId)
        }

        // 再武装闸门（捕获 catch 的终端写；先弹出的动作携带自己的错误，不被
        // 后续 armOnce 覆盖）后放行：done 写抛错 → 进入 catch。
        await statusStore.armOnce()
        await statusStore.releaseParked()
        #expect(await simRuntimeWaitUntil { await statusStore.totalParkedCalls == 2 })

        // catch 的终端写仍在飞：占用保持，后继依旧被拒——迟到 catch 没有
        // 可以覆写后继状态的时间窗（generation 守卫之外的结构性保证）。
        await #expect(throws: SimilarityError.analysisRunning) {
            try await runtime.analyze(sessionId: sessionId)
        }

        await statusStore.releaseParked()
        let firstOutcome = await simRuntimeAwaitTracker(firstTracker)
        #expect(firstOutcome?.failedDescription?.contains("SimRuntimeTerminalWriteBoom") == true)

        // A 已退出：B 进入并完成；终态是 B 的 done，A 的迟到 catch 未覆写任何后继状态。
        let successor = await simRuntimeRunOutcome {
            try await runtime.analyze(sessionId: sessionId)
        }
        #expect(successor == .succeeded)
        #expect(try await harness.sessionStore.get(id: sessionId)?.analysisStatus == "done")
        let runs = try await simRuntimeRunRecords(harness.db, sessionId)
        #expect(runs.map(\.status) == ["failed", "ok"])
    }
}

// MARK: - 测试专用：可武装的一次性状态写闸门

struct SimRuntimeTerminalWriteBoom: Error, Equatable {}

/// 包装真实 SessionStore：armOnce 后下一次 updateAnalysisStatus 挂起，直到
/// releaseParked；若 armOnce(error:) 指定错误，则放行时该次调用抛错
/// （模拟终端状态写失败 → 触发 analyze 的 catch 路径）。
///
/// 每个挂起调用在挂起前弹出自己的武装动作（错误随调用保存），因此后续
/// armOnce 不会覆盖先前挂起调用的行为。
actor SimRuntimeStatusGateStore: SessionStore {
    private struct ArmedAction {
        let error: SimRuntimeTerminalWriteBoom?
    }

    private let base: any SessionStore
    private var armedActions: [ArmedAction] = []
    private var parked: CheckedContinuation<Void, Never>?
    private var totalParks = 0

    init(base: any SessionStore) {
        self.base = base
    }

    func armOnce(error: SimRuntimeTerminalWriteBoom? = nil) {
        armedActions.append(ArmedAction(error: error))
    }

    var totalParkedCalls: Int { totalParks }

    func releaseParked() {
        let continuation = parked
        parked = nil
        continuation?.resume()
    }

    func updateAnalysisStatus(id: String, status: String) async throws {
        if !armedActions.isEmpty {
            let action = armedActions.removeFirst()
            totalParks += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked = continuation
            }
            if let error = action.error {
                throw error
            }
        }
        try await base.updateAnalysisStatus(id: id, status: status)
    }

    // MARK: SessionStore 透传

    func get(id: String) async throws -> SessionRecord? {
        try await base.get(id: id)
    }

    func create(name: String, source: String, sourcePath: String, truncatedImport: Bool) async throws -> SessionRecord {
        try await base.create(name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
    }

    func list() async throws -> [SessionRecord] {
        try await base.list()
    }

    func delete(id: String) async throws -> Bool {
        try await base.delete(id: id)
    }

    func deleteMany(ids: [String]) async throws -> Int {
        try await base.deleteMany(ids: ids)
    }

    func deleteSimilarityData(sessionId: String) async throws {
        try await base.deleteSimilarityData(sessionId: sessionId)
    }

    func updateName(id: String, name: String) async throws -> Bool {
        try await base.updateName(id: id, name: name)
    }

    func updateSourcePath(id: String, sourcePath: String) async throws -> Bool {
        try await base.updateSourcePath(id: id, sourcePath: sourcePath)
    }

    func updateStatus(id: String, status: String) async throws {
        try await base.updateStatus(id: id, status: status)
    }

    func updatePhotoCount(id: String, count: Int) async throws {
        try await base.updatePhotoCount(id: id, count: count)
    }

    func updateWritebackStatus(id: String, status: String) async throws {
        try await base.updateWritebackStatus(id: id, status: status)
    }

    func updateFailedWritebackCount(id: String, count: Int) async throws {
        try await base.updateFailedWritebackCount(id: id, count: count)
    }

    func reloadAckedAt(sessionId: String) async throws -> String? {
        try await base.reloadAckedAt(sessionId: sessionId)
    }

    func setReloadAckedAt(sessionId: String, iso: String) async throws -> Bool {
        try await base.setReloadAckedAt(sessionId: sessionId, iso: iso)
    }

    func indexSeq(id: String) async throws -> Int {
        try await base.indexSeq(id: id)
    }

    func bumpIndexSeq(id: String) async throws -> Int {
        try await base.bumpIndexSeq(id: id)
    }
}
