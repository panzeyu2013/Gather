// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave1Tests.swift
// Wave1 / task-6（G1/G2/G10）的回归测试：C1 桥脚本契约、reload 的"无选中不盲发"、
// 手动 Load Metadata 的显式 ack（含 Live API 落库），以及 VM 的三条新动作。
//
// 全程不 spawn osascript：脚本契约走文本断言，reload 语义走注入的假 AppleScript
// 运行器（CaptureOneBridge.appleScriptRunner 测试接缝），Live API 用例只碰内存 SQLite。
//
// 为什么脚本要按文本断言：G1 的根因不是"脚本不存在"而是"对象归属/属性归属错"，
// 静态字典核对照样会过；这里把 sdef 依据（application 级 selected variants、
// parent image.path、variant 级 reload metadata、document+variants 的 select）
// 钉成断言，改坏契约会直接红。
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

// MARK: - 脚本契约（G1 / G2）

@Suite("C1BridgeWave1 脚本契约（G1/G2）")
struct C1BridgeWave1ScriptContractTests {
    @Test("选中读取：application 级 selected variants + parent image.path，且不吞错")
    func selectedVariantsScriptUsesApplicationLevelSelection() {
        let script = CaptureOneBridge.selectedVariantsScript(appName: "Capture One")
        // sdef: selected variants code=csev 挂在 application 上（CaptureOne.sdef:244-247）。
        #expect(script.contains("selected variants"))
        #expect(!script.contains("selected variants of current document"))
        // variant 没有 path：路径经 parent image 的 path（:1081 / :1541）。
        #expect(script.contains("parent image of v"))
        #expect(script.contains("path of parentImage"))
        // G1 的一半是"错误被吞"：脚本里不得再有 on error 兜底。
        #expect(!script.contains("on error"))
    }

    @Test("在 C1 中选中：按 image.path 匹配 + document/variants 参数形式")
    func selectVariantsScriptMatchesSelectContract() {
        let script = CaptureOneBridge.selectVariantsScript(
            appName: "Capture One", paths: ["/shoot/a.cr2"])
        // variant 没有 path（旧脚本 every variant whose path 必然报错）。
        #expect(!script.contains("every variant of targetDoc whose path"))
        #expect(script.contains("every image of targetDoc whose path is p"))
        // sdef: select 的直接参数是 document，variant/variants 是具名参数（:1956-1966）。
        #expect(script.contains("select targetDoc variants variantsToSelect"))
        // C7 的 error 报告必须保留：脚本失败不能被当成"没匹配到"或落到 open -a。
        #expect(script.contains("error:"))
    }

    @Test("reload：对选中 variant 逐个调用，document 级调用已删除")
    func reloadMetadataScriptIsPerVariant() {
        let script = CaptureOneBridge.reloadMetadataScript(appName: "Capture One")
        // sdef: reload metadata 的直接参数是 variant（:1852-1855），document 不响应。
        #expect(script.contains("reload metadata v"))
        #expect(!script.contains("reload metadata of current document"))
        // 无选中时返回 0（宿主抛 .noSelection），不向任何对象盲发。
        #expect(script.contains("count of selectedVariantsList"))
        #expect(script.contains("return \"0\""))
    }

    @Test("reload 报告解析：数字才是成功，未知形状返回 nil")
    func reloadedVariantCountParsing() {
        #expect(CaptureOneBridge.reloadedVariantCount(from: "3") == 3)
        #expect(CaptureOneBridge.reloadedVariantCount(from: " 0 ") == 0)
        #expect(CaptureOneBridge.reloadedVariantCount(from: "") == nil)
        #expect(CaptureOneBridge.reloadedVariantCount(from: "ok") == nil)
    }

    @Test("无文档措辞归一：Can't get current document → C1_NO_DOCUMENT")
    func currentDocumentErrorsMapToNoDocument() {
        let error = CaptureOneBridge.classifyMessage("Capture One got an error: Can't get current document.")
        #expect(error == .noDocument)
        #expect(error.description == GatherErrorCode.C1_NO_DOCUMENT.rawValue)
    }

    @Test("错误码：.noSelection 走 C1_NO_SELECTED_PHOTOS，且满足 CodedError")
    func noSelectionCarriesStableCode() {
        let error = CaptureOneBridgeError.noSelection
        #expect(error.code == .C1_NO_SELECTED_PHOTOS)
        #expect(error.description == GatherErrorCode.C1_NO_SELECTED_PHOTOS.rawValue)
    }
}

// MARK: - reload 语义（G2）与选中读取的路径过滤

/// 组装注入式桥：app 名探测回固定值，其余脚本回给定输出/抛给定错误。
private func makeWave1Bridge(
    ack: LockedBox<Wave1AckState>,
    scriptOutput: @escaping @Sendable (String) throws -> String
) -> CaptureOneBridge {
    CaptureOneBridge(
        recordReloadAck: { sessionId in
            ack.lock.withLock { ack.ids.append(sessionId) }
        },
        appleScriptRunner: { script in
            // 应用名探测（System Events）必须回一个安全名字，否则桥会在预检阶段退出。
            if script.contains("System Events") { return "Capture One" }
            return try scriptOutput(script)
        })
}

private struct Wave1AckState {
    var ids: [String] = []
}

@Suite("C1BridgeWave1 reload 语义（G2）")
struct C1BridgeWave1ReloadTests {
    @Test("无选中（脚本回 0）→ 抛 .noSelection，且不写 durable ack")
    func noSelectionDoesNotWriteAck() async {
        let ack = LockedBox(Wave1AckState())
        let bridge = makeWave1Bridge(ack: ack) { _ in "0" }
        do {
            try await bridge.reloadMetadata(sessionId: "s1")
            Issue.record("无选中时 reload 必须失败，不能假装成功")
        } catch let error as CaptureOneBridgeError {
            #expect(error == .noSelection)
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("脚本报告形状不认识 → C1_SCRIPT_FAILED，且诊断保留原文")
    func unrecognizedReportSurfacesScriptFailed() async {
        let ack = LockedBox(Wave1AckState())
        let bridge = makeWave1Bridge(ack: ack) { _ in "reloaded" }
        do {
            try await bridge.reloadMetadata(sessionId: "s1")
            Issue.record("未知报告形状必须当脚本契约失败")
        } catch let error as CaptureOneBridgeError {
            guard case .scriptFailed(let message) = error else {
                Issue.record("期望 scriptFailed，实际 \(error)")
                return
            }
            #expect(message.contains("reloaded"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }

    @Test("成功重载（脚本回 2）→ 写 durable ack")
    func successWritesAck() async throws {
        let ack = LockedBox(Wave1AckState())
        let bridge = makeWave1Bridge(ack: ack) { _ in "2" }
        try await bridge.reloadMetadata(sessionId: "s1")
        #expect(ack.lock.withLock { ack.ids } == ["s1"])
    }

    @Test("脚本执行失败直接上浮 C1_SCRIPT_FAILED（不被吞成\"没有选中\"）")
    func scriptFailurePropagates() async {
        let ack = LockedBox(Wave1AckState())
        let bridge = makeWave1Bridge(ack: ack) { _ in
            throw CaptureOneBridgeError.scriptFailed("-1728 handled by host")
        }
        do {
            try await bridge.reloadMetadata(sessionId: "s1")
            Issue.record("脚本失败必须上浮")
        } catch let error as CaptureOneBridgeError {
            #expect(error == .scriptFailed("-1728 handled by host"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
        #expect(ack.lock.withLock { ack.ids }.isEmpty)
    }
}

@Suite("C1BridgeWave1 选中读取（G1）")
struct C1BridgeWave1SelectionReadTests {
    @Test("只返回存在且绝对路径；不存在的条目被过滤")
    func filtersMissingAndRelativePaths() async throws {
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-c1-\(UUID().uuidString).cr2").path
        #expect(FileManager.default.createFile(atPath: existing, contents: Data()))
        defer { try? FileManager.default.removeItem(atPath: existing) }
        let ack = LockedBox(Wave1AckState())
        let bridge = makeWave1Bridge(ack: ack) { _ in
            "\(existing)\n/definitely/not/exists.cr2\nrelative/file.cr2\n"
        }
        let paths = try await bridge.selectedPhotoPaths()
        #expect(paths == [existing])
    }

    @Test("脚本失败不再返回空数组（旧 on error 行为）")
    func scriptFailureDoesNotLookLikeEmptySelection() async {
        let ack = LockedBox(Wave1AckState())
        let bridge = makeWave1Bridge(ack: ack) { _ in
            throw CaptureOneBridgeError.scriptFailed("Can't get parent image")
        }
        do {
            _ = try await bridge.selectedPhotoPaths()
            Issue.record("脚本失败必须以错误上浮，而不是空选中")
        } catch let error as CaptureOneBridgeError {
            #expect(error == .scriptFailed("Can't get parent image"))
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
    }
}

// MARK: - Live API：手动 ack 落库（G2）

private final class Wave1MutationPort: MetadataMutationPort, @unchecked Sendable {
    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending")
    }
}

private final class Wave1WritebackPort: CullingWritebackPort {
    func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions,
        photoIds: Set<String>?,
        keywordAdditions: [String: [String]]?
    ) async throws -> WritebackPreview {
        WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    }

    func persistAttributes(items: [WritebackItem]) throws {}

    func execute(
        sessionId: String, module: String, items: [WritebackItem]
    ) async throws -> WritebackResult {
        WritebackResult(
            totalAffected: 0, written: 0, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: "Written: 0, Failed: 0, Skipped: 0")
    }

    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult {
        try await execute(sessionId: sessionId, module: module, items: [])
    }

    func getItems(sessionId: String, module: String, status: String?) throws -> [WritebackItem] {
        []
    }
}

private struct Wave1CullingFixture {
    let sessionRepo: SessionRepo
    let sessionId: String
    let api: LiveCullingAPI

    init() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "wave1-c1", source: "test")
        let decisionRepo = CullingDecisionRepo(connection: db)
        let service = CullingServiceFactory.make(
            photoRepo: PhotoRepo(connection: db),
            cullingDecisionRepo: decisionRepo,
            similarityResultRepo: SimilarityResultRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            metadataMutations: Wave1MutationPort(),
            writeback: Wave1WritebackPort(),
            cullingHistoryRepo: CullingHistoryRepo(connection: db))
        let triage = TriageService(
            repository: TriageRepo(connection: db),
            decisions: decisionRepo,
            history: CullingHistoryRepo(connection: db),
            transactions: db)
        self.sessionRepo = sessionRepo
        self.sessionId = session.id
        self.api = LiveCullingAPI(
            cullingService: service, triageService: triage, sessionRepo: sessionRepo)
    }
}

private func wave1GatherError(_ body: () async throws -> Void) async -> GatherError? {
    do {
        try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

@Suite("C1BridgeWave1 手动 ack（Live API）")
struct C1BridgeWave1ManualAckAPITests {
    @Test("acknowledgeManualReload：写 sessions.reload_acked_at，syncStatus 可见")
    func ackWritesDurableColumn() async throws {
        let fixture = try Wave1CullingFixture()
        #expect(try fixture.sessionRepo.get(id: fixture.sessionId)?.reloadAckedAt == nil)
        let before = try await fixture.api.syncStatus(fixture.sessionId)
        #expect(before.reloadAckedAt == nil)

        #expect(try await fixture.api.acknowledgeManualReload(fixture.sessionId))

        #expect(try fixture.sessionRepo.get(id: fixture.sessionId)?.reloadAckedAt != nil)
        let after = try await fixture.api.syncStatus(fixture.sessionId)
        #expect(after.reloadAckedAt != nil)
    }

    @Test("acknowledgeManualReload：会话不存在 → SESSION_NOT_FOUND（不写孤儿列）")
    func missingSessionReportsNotFound() async throws {
        let fixture = try Wave1CullingFixture()
        let error = await wave1GatherError {
            _ = try await fixture.api.acknowledgeManualReload("missing-session")
        }
        #expect(error?.code == .SESSION_NOT_FOUND)
    }

    @Test("acknowledgeManualReload：空 sessionId → INVALID_PARAM")
    func blankSessionReportsInvalidParam() async throws {
        let fixture = try Wave1CullingFixture()
        let error = await wave1GatherError {
            _ = try await fixture.api.acknowledgeManualReload("   ")
        }
        #expect(error?.code == .INVALID_PARAM)
    }
}

// MARK: - VM 三条新动作（G2 手动 ack / G2 失败提示 / G10 在 C1 中显示）

/// C1 往返三协议的测试替身（可注入 reload/select 错误与自动 reload 失败）。
///
/// 与生产的 C1RoundTripCoordinator 同一形状：一个 @MainActor 类同时满足
/// C1RoundTripReloading / C1RoundTripExtending / CaptureOneBridging，这样 VM 的
/// "协调器优先"分支与"在 C1 中显示"分支都能被覆盖。
@MainActor
private final class Wave1FakeC1RoundTrip: C1RoundTripReloading, C1RoundTripExtending, CaptureOneBridging {
    var reloadCalls: [String] = []
    var reloadError: (any Error)?
    var autoReloadFailure: C1AutoReloadFailure?
    var selectCalls: [[String]] = []
    var selectError: (any Error)?
    var selectResult = C1SelectionOutcome(
        method: .appleScript, paths: [], notFound: [], appName: "Capture One")

    func reloadMetadata(sessionId: String) async throws {
        reloadCalls.append(sessionId)
        if let reloadError { throw reloadError }
    }

    func noteDeliveryStateChanged(sessionId: String) {}

    func currentAutoReloadFailure() -> C1AutoReloadFailure? { autoReloadFailure }

    func clearAutoReloadFailure() { autoReloadFailure = nil }

    func selectVariants(paths: [String]) async throws -> C1SelectionOutcome {
        selectCalls.append(paths)
        if let selectError { throw selectError }
        return selectResult
    }

    func adjustmentHints(paths: [String]) -> [C1AdjustmentHint] {
        paths.map { C1AdjustmentHint.none(photoPath: $0) }
    }

    func selectedPhotoPaths() async throws -> [String] { [] }

    func checkHealth() async -> Result<String, CaptureOneBridgeError> { .success("fake") }

    func preflight() async -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: true, appRunning: true, automationAuthorized: true,
            documentOpen: true, timedOut: false, appName: "Capture One")
    }

    nonisolated static func documentProbeScript(appName: String) -> String {
        "wave1-probe:" + appName
    }
}

@MainActor
private func makeWave1CullingStack(
    captureOne: any CaptureOneBridging
) -> (CullingViewModel, B8CullingAPIStub) {
    let culling = B8CullingAPIStub()
    let viewModel = CullingViewModel(
        sessionId: "s1",
        culling: culling,
        navigation: B8NavigationAPIStub(),
        metadata: B6bMetadataAPIStub(),
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: captureOne)
    return (viewModel, culling)
}

/// 重载成功后的投影：ack 已写 + 仍有待确认行（confirm 按钮在状态条里可用）。
private func wave1AckedSyncStatus() -> CullingSyncStatus {
    CullingSyncStatus(
        summary: b8SyncSummary(sessionId: "s1", written: 2),
        reloadAckedAt: "2026-11-11T08:00:00.000Z")
}

@Suite("C1BridgeWave1 VM 动作（G2/G10）")
@MainActor
struct C1BridgeWave1ViewModelTests {
    @Test("acknowledgeManualReload：写 ack、置 reloadAcked、可确认同步")
    func manualAckRefreshesGate() async {
        let fake = Wave1FakeC1RoundTrip()
        let (viewModel, culling) = makeWave1CullingStack(captureOne: fake)
        culling.syncStatusResult = wave1AckedSyncStatus()

        await viewModel.acknowledgeManualReload()

        #expect(culling.acknowledgeManualReloadCalls == ["s1"])
        #expect(viewModel.reloadAcked)
        #expect(viewModel.canConfirmSync)
        #expect(viewModel.notice != nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("acknowledgeManualReload 失败 → 错误码可见，不伪造已确认")
    func manualAckFailureSurfacesCode() async {
        let fake = Wave1FakeC1RoundTrip()
        let (viewModel, culling) = makeWave1CullingStack(captureOne: fake)
        culling.acknowledgeManualReloadError = GatherError(code: .SESSION_NOT_FOUND)

        await viewModel.acknowledgeManualReload()

        #expect(viewModel.errorMessage?.code == GatherErrorCode.SESSION_NOT_FOUND.rawValue)
        #expect(!viewModel.reloadAcked)
    }

    @Test("reload 失败：C1RoundTripError 码值上屏（不再是通用文案）")
    func reloadFailureMapsRoundTripCode() async {
        let fake = Wave1FakeC1RoundTrip()
        fake.reloadError = C1RoundTripError.bridgeFailed(
            code: GatherErrorCode.C1_NO_SELECTED_PHOTOS.rawValue, message: "no selection")
        let (viewModel, _) = makeWave1CullingStack(captureOne: fake)

        await viewModel.reloadCaptureOne()

        #expect(fake.reloadCalls == ["s1"])
        #expect(viewModel.errorMessage?.code == GatherErrorCode.C1_NO_SELECTED_PHOTOS.rawValue)
    }

    @Test("reload 成功：走协调器、reloadAcked 置位、发布提示")
    func reloadSuccessSetsAcked() async {
        let fake = Wave1FakeC1RoundTrip()
        let (viewModel, culling) = makeWave1CullingStack(captureOne: fake)
        culling.syncStatusResult = wave1AckedSyncStatus()

        await viewModel.reloadCaptureOne()

        #expect(fake.reloadCalls == ["s1"])
        #expect(viewModel.reloadAcked)
        #expect(viewModel.notice != nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("showInCaptureOne：有选择集时把选择集路径交给 C1")
    func showInCaptureOneUsesSelection() async {
        let fake = Wave1FakeC1RoundTrip()
        fake.selectResult = C1SelectionOutcome(
            method: .appleScript, paths: ["/shoot/p1.jpg"], notFound: [], appName: "Capture One")
        let (viewModel, culling) = makeWave1CullingStack(captureOne: fake)
        culling.pageResult = b8CullingPage([
            b8CullingAsset("p1"), b8CullingAsset("p2"),
        ])
        await viewModel.load()
        viewModel.toggleSelection("p1")

        await viewModel.showInCaptureOne()

        #expect(fake.selectCalls == [["/shoot/p1.jpg"]])
        #expect(viewModel.notice != nil)
    }

    @Test("showInCaptureOne：无选择集时用当前照片")
    func showInCaptureOneFallsBackToCurrentPhoto() async {
        let fake = Wave1FakeC1RoundTrip()
        fake.selectResult = C1SelectionOutcome(
            method: .appleScript, paths: ["/shoot/p2.jpg"], notFound: [], appName: "Capture One")
        let (viewModel, culling) = makeWave1CullingStack(captureOne: fake)
        culling.pageResult = b8CullingPage([b8CullingAsset("p2")])
        await viewModel.load()

        await viewModel.showInCaptureOne()

        #expect(fake.selectCalls == [["/shoot/p2.jpg"]])
    }

    @Test("showInCaptureOne：部分不在当前目录时提示两个计数")
    func showInCaptureOneReportsNotFound() async {
        let fake = Wave1FakeC1RoundTrip()
        fake.selectResult = C1SelectionOutcome(
            method: .appleScript, paths: ["/shoot/p1.jpg"],
            notFound: ["/elsewhere/p9.jpg"], appName: "Capture One")
        let (viewModel, culling) = makeWave1CullingStack(captureOne: fake)
        culling.pageResult = b8CullingPage([b8CullingAsset("p1")])
        await viewModel.load()

        await viewModel.showInCaptureOne()

        let notice = viewModel.notice?.resolve(with: L10n(language: .zhCN)) ?? ""
        #expect(notice.contains("1") && notice.contains("1 张不在"))
        #expect(viewModel.errorMessage == nil)
    }

    @Test("自动 reload 因\"没有选中照片\"失败 → 提示可执行的下一步")
    func autoReloadNoSelectionShowsActionableHint() async {
        let fake = Wave1FakeC1RoundTrip()
        fake.autoReloadFailure = C1AutoReloadFailure(
            sessionId: "s1",
            code: GatherErrorCode.C1_NO_SELECTED_PHOTOS.rawValue,
            message: "no selected variant",
            attemptedAt: "2026-11-11T08:00:00.000Z")
        let (viewModel, _) = makeWave1CullingStack(captureOne: fake)

        viewModel.handleC1AutoReloadFailure()

        #expect(viewModel.errorMessage?.origin == .localValidation)
        #expect(viewModel.errorMessage?.code.contains("Capture One 没有选中的照片") == true)
    }
}