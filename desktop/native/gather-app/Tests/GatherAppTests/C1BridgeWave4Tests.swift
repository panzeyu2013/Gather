// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave4Tests.swift
// Wave4a / task-35 回归：A3 写回只表达 keep（reject 不写 pick）、A4 跨页选择写回不静默截断、
// A5 新建工作区与导入文件夹共用 C1 Session 识别（扫描根=Capture）且 badge 不谎报。
//
// 不连真 C1、不跑 osascript：CaptureOneBridging 用记录型替身；目录识别用真实临时目录
// （C1SessionDirectoryResolver 的 FileManager 默认接缝，测完即删）。
import Foundation
import Testing
import GatherProtocol
import GatherTestSupport
@testable import GatherUI

// MARK: - 记录型桥替身

/// 记录型替身（struct + LockedBox：Sendable 隐式满足，无需 @unchecked）。
private struct Wave4RecordingBridge: CaptureOneBridging {
    private let box = LockedBox(Wave4BridgeState())

    var receivedItems: [C1VariantWritebackItem] {
        box.lock.withLock { box.items }
    }
    var lastSessionId: String? {
        box.lock.withLock { box.sessionId }
    }

    func selectedPhotoPaths() async throws -> [String] { [] }
    func reloadMetadata(sessionId: String) async throws {}
    func checkHealth() async -> Result<String, CaptureOneBridgeError> { .success("fake") }
    func preflight() async -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: true, appRunning: true, automationAuthorized: true,
            documentOpen: true, timedOut: false, appName: "Capture One")
    }
    nonisolated static func documentProbeScript(appName: String) -> String { "wave4:" + appName }

    func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport {
        box.lock.withLock {
            box.items = items
            box.sessionId = sessionId
            // 默认：全部写入（按 items 数）。
            return C1VariantWritebackReport(written: items.count)
        }
    }
}

private struct Wave4BridgeState {
    var items: [C1VariantWritebackItem] = []
    var sessionId: String?
}

@MainActor
private func makeWave4CullingVM(
    bridge: Wave4RecordingBridge,
    session: SessionData? = nil
) -> CullingViewModel {
    CullingViewModel(
        sessionId: "s1",
        culling: B8CullingAPIStub(),
        navigation: B8NavigationAPIStub(),
        metadata: B6bMetadataAPIStub(),
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: bridge,
        session: session.map { B8SessionAPIStub(session: $0) })
}

private func wave4Asset(
    _ id: String,
    pickState: PickState = .unreviewed,
    rating: Double = 0,
    colorLabel: CaptureOneColorLabel = .none
) -> CullingAsset {
    CullingAsset(
        photo: b8CullingPhoto(id),
        state: b8CullingState(id, pickState: pickState, rating: rating, colorLabel: colorLabel),
        xmpPath: "/shoot/\(id).xmp",
        syncStatus: .clean,
        people: [],
        keywords: [],
        linkedVariantCount: 1,
        faceBboxes: [])
}

private func wave4SessionData(sourcePath: String) -> SessionData {
    SessionData(
        id: "s1",
        name: "C1 Session",
        status: .draft,
        photoCount: 0,
        analysisStatus: .idle,
        writebackStatus: .idle,
        importSource: "local",
        sourcePath: sourcePath,
        failedWritebackCount: 0,
        truncatedImport: false,
        createdAt: "2026-11-11T08:00:00.000Z",
        updatedAt: "2026-11-11T08:00:00.000Z")
}

// MARK: - A3：keep-only 映射

@Suite("C1BridgeWave4 A3 变体写回 keep-only")
@MainActor
struct C1BridgeWave4PickMappingTests {
    @Test("写回 items：picked→pick=true；reject/unreviewed→nil（不写 pick）")
    func itemsWriteKeepOnly() {
        let vm = makeWave4CullingVM(bridge: Wave4RecordingBridge())
        vm.page = b8CullingPage([
            wave4Asset("keep", pickState: .picked, rating: 4, colorLabel: .green),
            wave4Asset("reject", pickState: .rejected),
            wave4Asset("unreviewed", pickState: .unreviewed),
        ])
        vm.selectedPhotoIds = ["keep", "reject", "unreviewed"]
        let items = vm.variantWritebackItems
        #expect(items.count == 3)
        #expect(items.map(\.pick) == [true, nil, nil])
        #expect(items.map(\.rating) == [4, 0, 0])
        #expect(items.map(\.colorTag) == [4, 0, 0])
    }
}

// MARK: - A4：跨页选择不静默截断

@Suite("C1BridgeWave4 A4 跨页选择写回提示")
@MainActor
struct C1BridgeWave4CrossPageTests {
    @Test("跨页：只写当前页，notice 明示剩余张数（不再静默截断）")
    func crossPageSelectionIsReported() async {
        let bridge = Wave4RecordingBridge()
        let vm = makeWave4CullingVM(bridge: bridge)
        vm.page = b8CullingPage([wave4Asset("a"), wave4Asset("b")])
        // 选择集包含另一页的 c：写回只能覆盖当前页 a/b。
        vm.selectedPhotoIds = ["a", "b", "c"]
        await vm.writeVariantJudgementsToCaptureOne()
        #expect(bridge.receivedItems.count == 2)
        #expect(vm.errorMessage == nil)
        guard case .text(let text)? = vm.notice?.payload else {
            Issue.record("期望文本 notice，实际 \(String(describing: vm.notice))")
            return
        }
        #expect(text.key.contains("仅当前页"))
        #expect(text.params == ["2", "3"])
    }

    @Test("无跨页：全部可见时不出现跨页提示")
    func noCrossPageKeepsSuccessNotice() async {
        let bridge = Wave4RecordingBridge()
        let vm = makeWave4CullingVM(bridge: bridge)
        vm.page = b8CullingPage([wave4Asset("a"), wave4Asset("b")])
        vm.selectedPhotoIds = ["a", "b"]
        await vm.writeVariantJudgementsToCaptureOne()
        #expect(bridge.receivedItems.count == 2)
        guard case .text(let text)? = vm.notice?.payload else {
            Issue.record("期望文本 notice")
            return
        }
        #expect(!text.key.contains("仅当前页"))
    }
}

/// 临时目录清理（测试专用；不用 try? 以符合本波约束）。
private func cleanUp(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) } catch {
        // 清理失败不影响断言结果。
    }
}

// MARK: - A5：Session 三目录识别共用 + badge 不谎报

@Suite("C1BridgeWave4 A5 Session 导入规划")
@MainActor
struct C1BridgeWave4SessionPlanTests {
    private func makeSessionRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wave4-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Capture"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Selects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        return root
    }

    @Test("importPlan：真实目录上只扫 Capture；普通目录不重定向")
    func importPlanUsesRealDirectoryLister() throws {
        let root = try makeSessionRoot()
        defer { cleanUp(root) }
        let plan = C1SessionDirectoryResolver.importPlan(root: root.path)
        #expect(ScanPath.canonical(plan?.scanRoot ?? "") == ScanPath.canonical(
            root.appendingPathComponent("Capture").path))
        #expect(plan?.scansCaptureOnly == true)
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wave4-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { cleanUp(plain) }
        #expect(C1SessionDirectoryResolver.importPlan(root: plain.path) == nil)
    }

    @Test("badge 依据：扫描根=Capture 才是\"仅导入 Capture\"，Session 根不谎报")
    func scanRootFlagMatchesActualSourcePath() async throws {
        let root = try makeSessionRoot()
        defer { cleanUp(root) }
        let capture = root.appendingPathComponent("Capture").path
        // 重定向后的会话：sourcePath = Capture。
        let redirected = makeWave4CullingVM(
            bridge: Wave4RecordingBridge(),
            session: wave4SessionData(sourcePath: capture))
        await redirected.loadCaptureOneSessionLayout()
        #expect(redirected.captureOneSessionLayout != nil)
        #expect(redirected.captureOneSessionScanIsCaptureOnly)
        // 旧会话/未重定向：sourcePath = Session 根。
        let legacy = makeWave4CullingVM(
            bridge: Wave4RecordingBridge(),
            session: wave4SessionData(sourcePath: root.path))
        await legacy.loadCaptureOneSessionLayout()
        #expect(legacy.captureOneSessionLayout != nil)
        #expect(!legacy.captureOneSessionScanIsCaptureOnly)
    }
}
