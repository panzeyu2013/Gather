// desktop/native/gather-app/Tests/GatherAppTests/AITriageImportTriggerTests.swift
// Wave5 batch2（E1/E2）：自动初审的入口覆盖 / 状态卡 / 人脸前置。
//
// 覆盖（不依赖真实服务，除 SettingsService/JobService 的默认值选择外）：
// 1. Dashboard「新建工作区」→ AITriageUIBridge → Host 注入闭包收到 sessionId；
// 2. AppImport「加照片到已有工作区」→ afterAdd 收到 sessionId（失败也不影响导入）；
// 3. AITriageStatusStore 状态写入/替换/清空，以及 pipeline 结果 → 状态卡相位映射；
// 4. E2 人脸前置判定：有观测 / 缺观测 / 查询失败（不阻塞）；
// 5. 两个开关默认关闭时，调度器把状态置为「未启用」（可见性，不只写日志）。
import Foundation
import Testing
import os
@testable import GatherUI
@testable import GatherHost
import GatherProtocol
import GatherPersistence
import GatherApplication
import GatherTestSupport

// MARK: - 最小 SessionAPI / JobAPI 替身（只实现导入路径用到的两个方法）

private struct StubImportSessionAPI: SessionAPI {
    func list() async throws -> [SessionData] { throw Self.unused() }
    func get(_ sessionId: String) async throws -> SessionData { throw Self.unused() }
    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        throw Self.unused()
    }
    func update(_ input: SessionUpdateParams) async throws -> SessionData { throw Self.unused() }
    func delete(_ input: Confirmed<SessionDeleteInput>) async throws { throw Self.unused() }
    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        AddPhotoResult(added: input.filepaths.count, skipped: 0,
                       total: input.filepaths.count, failedFiles: [])
    }
    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        throw Self.unused()
    }
    func setSourceRoot(
        _ input: Confirmed<SessionSetSourceRootInput>
    ) async throws -> SessionData { throw Self.unused() }
    func status(_ sessionId: String) async throws -> WorkspaceStatus { throw Self.unused() }

    private static func unused() -> Error {
        GatherError.invalidParameter(field: "stub", reason: "not used by this test")
    }
}

private struct StubImportJobAPI: JobAPI {
    func list(_ filter: JobListFilter) async throws -> [AnalysisJobData] { [] }
    func cancel(_ jobId: String) async throws -> Bool { false }
    func retry(_ jobId: String) async throws -> Bool { false }
    func clearCompleted(_ input: Confirmed<ClearCompletedInput>) async throws -> Int { 0 }
    func start(_ request: JobRequest) async throws -> JobHandle {
        JobHandle(id: "job-scan", events: AsyncStream<JobEvent> { $0.finish() })
    }
}

// MARK: - 最小 Dashboard provider（只覆盖 createSession 成功路径）

private final class StubDashboardProvider: DashboardDataProvider, @unchecked Sendable {
    private(set) var createdNames: [String] = []

    func listSessions() async throws -> [SessionData] { [] }

    func createSession(name: String, source: String, sourcePath: String) async throws -> SessionData {
        createdNames.append(name)
        return Self.session(id: "new-\(createdNames.count)", name: name, sourcePath: sourcePath)
    }

    func deleteSession(_ sessionId: String, confirmed: Bool) async throws {}

    func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? { nil }

    func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] { [] }

    func cancelJob(_ jobId: String) async throws -> Bool { true }

    func retryJob(_ jobId: String) async throws -> Bool { true }

    func clearCompletedJobs(includeFailed: Bool) async throws -> Int { 0 }

    static func session(
        id: String, name: String = "会话", sourcePath: String = ""
    ) -> SessionData {
        SessionData(
            id: id,
            name: name,
            status: .photosLoaded,
            photoCount: 0,
            analysisStatus: .idle,
            writebackStatus: .idle,
            importSource: "folder",
            sourcePath: sourcePath,
            failedWritebackCount: 0,
            truncatedImport: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }
}

/// 显式 optional 化：避免「Optional<Phase> == .case」的隐式成员解析歧义。
@MainActor
private func currentPhase(
    _ store: AITriageStatusStore, _ sessionId: String
) -> AITriageStatusStore.Phase? {
    store.phase(sessionId: sessionId)
}

/// E3：记录分组产物准备是否被调度（@Sendable 闭包不能捕获可变局部变量）。
///
/// final + 唯一存储属性是不可变的 OSAllocatedUnfairLock → 可直接声明 Sendable，
/// 不需要 @unchecked（cleanup ratchet 禁止新增 unchecked 逃逸口）。
private final class GroupArtifactsCallProbe: Sendable {
    private struct State {
        var sessions: [String] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var calls: [String] { lock.withLock { $0.sessions } }

    func record(_ sessionId: String) {
        lock.withLock { $0.sessions.append(sessionId) }
    }
}

private func stubSummary() -> TriageSummary {
    TriageSummary(
        counts: TriageCounts(keep: 3, reject: 1, review: 2, total: 6, coverage: 1),
        stale: false, policyVersion: "triage-v2", inputFingerprint: "fp-1",
        generatedAt: "2026-11-11T00:00:00Z")
}

// .serialized：本套件读写进程内全局 AITriageStatusStore / AITriageUIBridge，
// 并行会互相清空状态（不是产品缺陷，是测试隔离要求）。
@Suite("自动初审：入口与状态（Wave5 batch2）", .serialized)
@MainActor
struct AITriageImportTriggerTests {
    // MARK: 入口覆盖

    @Test("Dashboard 新建工作区 → UI 桥把 sessionId 交给 Host 注入的处理闭包")
    func dashboardCreateNotifiesTriageBridge() async {
        var received: [String] = []
        AITriageUIBridge.onSessionCreated = { received.append($0) }
        defer { AITriageUIBridge.onSessionCreated = nil }

        let viewModel = DashboardViewModel(provider: StubDashboardProvider())
        _ = await viewModel.createSession(
            name: "婚礼", sourcePath: "/tmp/wedding", with: L10n(language: .zhCN))

        // 全局桥会被并行套件里的其它 Dashboard 用例同时调用（本套件 .serialized 只保证
        // 套件内串行），因此只断言"本次建库的 sessionId 确实交给了桥"，不锁死数组形状。
        #expect(received.contains("new-1"))
    }

    @Test("AppImport 加照片到已有工作区 → afterAdd 收到 sessionId")
    func importIntoSessionInvokesAfterAdd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-ai-triage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("a.jpg")
        try Data("fixture".utf8).write(to: photo)

        var received: [String] = []
        await AppImport.importFiles(
            [photo.path],
            into: "s1",
            sessionAPI: StubImportSessionAPI(),
            jobAPI: StubImportJobAPI(),
            l10n: L10n(language: .zhCN),
            afterAdd: { sessionId in received.append(sessionId) })

        #expect(received == ["s1"])
    }

    // MARK: 状态卡

    @Test("状态卡 store：写入/替换/清空")
    func statusStoreRoundtrip() {
        let store = AITriageStatusStore.shared
        store.reset()
        defer { store.reset() }
        #expect(currentPhase(store, "s1") == nil)
        store.set(sessionId: "s1", phase: .waitingIndex)
        #expect(currentPhase(store, "s1") == Optional(.waitingIndex))
        store.set(sessionId: "s1", phase: .done(keep: 3, reject: 1, review: 2))
        #expect(currentPhase(store, "s1") == Optional(.done(keep: 3, reject: 1, review: 2)))
        store.clear(sessionId: "s1")
        #expect(currentPhase(store, "s1") == nil)
    }

    @Test("pipeline 结果 → 状态卡相位（done / skipped / stopped / failed）")
    func outcomeMapsToStatusPhase() {
        let done = AITriageAutoOutcome(stage: .done, summary: stubSummary())
        #expect(AITriageImportTrigger.statusPhase(for: done)
            == AITriageStatusStore.Phase.done(keep: 3, reject: 1, review: 2))

        let skipped = AITriageAutoOutcome(stage: .skipped, reason: "triage-disabled")
        #expect(AITriageImportTrigger.statusPhase(for: skipped)
            == AITriageStatusStore.Phase.skipped("triage-disabled"))

        let stopped = AITriageAutoOutcome(stage: .stopped, reason: "quality-timeout")
        #expect(AITriageImportTrigger.statusPhase(for: stopped)
            == AITriageStatusStore.Phase.stopped("quality-timeout"))

        let failed = AITriageAutoOutcome(stage: .stopped, reason: "failed: injected")
        #expect(AITriageImportTrigger.statusPhase(for: failed)
            == AITriageStatusStore.Phase.failed("failed: injected"))
    }

    @Test("两个开关默认关闭 → 调度器置「未启用」（失败/跳过必须可见）")
    func disabledSettingsVisibleInStatusStore() throws {
        let db = try makeTestDB()
        let settings = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let groupProbe = GroupArtifactsCallProbe()
        let scheduler = AITriageAutoScheduler(
            jobService: jobService,
            database: db,
            settings: settings,
            hasFaceObservations: { _ in true },
            enqueueFaceAnalysis: { _ in },
            ensureGroupArtifacts: { sessionId in
                groupProbe.record(sessionId)
                return .alreadyReady
            })
        let store = AITriageStatusStore.shared
        store.reset()
        defer { store.reset() }

        scheduler.schedule(sessionId: "s1")
        #expect(currentPhase(store, "s1") == Optional(.notEnabled))
        #expect(groupProbe.calls.isEmpty,
            "triage 未启用时整条自动初审（含分组分析）都应跳过，不做无用扫描")
    }

    // MARK: 人脸前置（E2）

    @Test("E2：有观测=present；无观测=missing；查询抛错=queryFailed（不阻塞）")
    func facePrerequisiteStates() {
        #expect(AITriageImportTrigger.facePrerequisite(
            sessionId: "s1", hasFaceObservations: { _ in true }) == .present)
        #expect(AITriageImportTrigger.facePrerequisite(
            sessionId: "s1", hasFaceObservations: { _ in false }) == .missing)
        #expect(AITriageImportTrigger.facePrerequisite(
            sessionId: "s1",
            hasFaceObservations: { _ in
                throw GatherError.invalidParameter(field: "face", reason: "injected")
            }) == .queryFailed)

        // 缺观测 → 入队 face.analyze，但状态停在"待人脸分析"、pipeline 不等待。
        let missingPlan = AITriageFacePlan.make(from: .missing)
        #expect(missingPlan.enqueueFaceAnalysis)
        #expect(missingPlan.phase == .waitingFace)
        // 有观测/查询失败 → 直接生成，不入队、不阻塞。
        let presentPlan = AITriageFacePlan.make(from: .present)
        #expect(!presentPlan.enqueueFaceAnalysis)
        #expect(presentPlan.phase == .generating)
        let failedPlan = AITriageFacePlan.make(from: .queryFailed)
        #expect(!failedPlan.enqueueFaceAnalysis)
        #expect(failedPlan.phase == .generating)
    }
}
