// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave4bTests.swift
// Wave4b / task-41 回归（C1 P2）：自动 reload 先 select 写盘照片、primary variant 回退文案、
// malformed 行计数、latestScanJob 稳定选择、Hot Folder 安装判定、MetadataSyncBar 动作注入。
// Wave5 / task-11：增补 R12「在 C1 中显示」的 deselect-first 契约（见下方 R12 套件）。
//
// 不连真 C1（注入 appleScriptRunner）、不跑 GUI；扫描 job 用 DTO 直接构造。
import Foundation
import Testing

/// 脚本/ack 收集器（LockedBox 的动态成员只能映射到 State 的具名属性）。
private struct ScriptLog {
    var items: [String] = []
}
import GatherProtocol
import GatherPersistence
import GatherApplication
import GatherTestSupport
@testable import GatherUI
@testable import GatherHost

// MARK: - 自动 reload：先 select 再 reload（P2 回路断点）

@Suite("C1BridgeWave4b reload 前自动 select")
struct C1BridgeWave4bPreselectTests {
    private func makeBridge(
        scripts: LockedBox<ScriptLog>,
        ack: LockedBox<ScriptLog>,
        written: @escaping (String) throws -> [String] = { _ in [] }
    ) -> CaptureOneBridge {
        CaptureOneBridge(
            recordReloadAck: { sessionId in ack.lock.withLock { ack.items.append(sessionId) } },
            appleScriptRunner: { script in
                scripts.lock.withLock { scripts.items.append(script) }
                if script.contains("System Events") { return "Capture One" }
                if script.contains("select targetDoc variants") { return "1\n" }
                return "2"
            },
            writtenPhotoPaths: written)
    }

    @Test("先按写盘路径 select，再 reload；顺序固定且 ack 照常")
    func preselectsBeforeReload() async throws {
        let scripts = LockedBox(ScriptLog())
        let ack = LockedBox(ScriptLog())
        let bridge = makeBridge(scripts: scripts, ack: ack) { _ in
            ["/shoot/a.cr2", "/shoot/b.cr2"]
        }
        try await bridge.reloadMetadata(sessionId: "s1")
        let all = scripts.lock.withLock { scripts.items }
        let selectIndex = try #require(all.firstIndex { $0.contains("select targetDoc variants") })
        let reloadIndex = try #require(all.firstIndex { $0.contains("reload metadata v") })
        #expect(selectIndex < reloadIndex)
        #expect(all[selectIndex].contains("/shoot/a.cr2"))
        #expect(ack.lock.withLock { ack.items } == ["s1"])
    }

    @Test("未接线写盘路径：退回旧行为（只 reload，不 select）")
    func withoutWrittenPathsKeepsLegacyReload() async throws {
        let scripts = LockedBox(ScriptLog())
        let ack = LockedBox(ScriptLog())
        let bridge = makeBridge(scripts: scripts, ack: ack)
        try await bridge.reloadMetadata(sessionId: "s1")
        let all = scripts.lock.withLock { scripts.items }
        #expect(!all.contains { $0.contains("select targetDoc variants") })
        #expect(all.contains { $0.contains("reload metadata v") })
    }

    @Test("写盘路径读取抛错：仍 reload（不因预选失败阻断门禁收口）")
    func preselectFailureDoesNotBlockReload() async throws {
        let scripts = LockedBox(ScriptLog())
        let ack = LockedBox(ScriptLog())
        let bridge = makeBridge(scripts: scripts, ack: ack) { _ in
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        try await bridge.reloadMetadata(sessionId: "s1")
        #expect(ack.lock.withLock { ack.items } == ["s1"])
        #expect(scripts.lock.withLock { scripts.items }.contains { $0.contains("reload metadata v") })
    }
}

// MARK: - primary variant 回退（三个读取脚本）

@Suite("C1BridgeWave4b 选中读取回退")
struct C1BridgeWave4bSelectionFallbackTests {
    @Test("三段读取脚本都允许受控回退 primary variant（受控 ≠ 整体吞错）")
    func readScriptsFallBackToPrimaryVariant() {
        let scripts = [
            CaptureOneBridge.selectedVariantsScript(appName: "Capture One"),
            CaptureOneBridge.reloadMetadataScript(appName: "Capture One"),
            CaptureOneBridge.selectedVariantJudgementsScript(appName: "Capture One"),
        ]
        for script in scripts {
            #expect(script.contains("primary variant"))
            #expect(script.contains("on error"))
            #expect(!script.contains("on error return"))
        }
        // 空选中不是错误：fallback 只在 on error 分支（空列表仍按空处理）。
        let readScript = CaptureOneBridge.selectedVariantsScript(appName: "Capture One")
        #expect(readScript.contains("set selectedVariantsList to {}"))
    }

    @Test("G3 畸形行计数进快照（不再静默丢弃）")
    func malformedLinesAreCounted() async throws {
        let bridge = CaptureOneBridge(appleScriptRunner: { script in
            if script.contains("System Events") { return "Capture One" }
            return "P/no-such-file.cr2\tR3\tT0\tK1\nBROKEN\n"
        })
        let snapshot = try await bridge.selectedVariantSnapshot()
        #expect(snapshot.malformedLines == 1)
        #expect(snapshot.paths.isEmpty)
    }
}

// MARK: - R12：在 C1 中显示 = 替换选中（select 前先 deselect）

/// Wave5（2026-11-11，Batch1 C1 写回正确性）R12 回归。
///
/// C1 的 select 是"加入当前集选中"（sdef:1956 "Add one or more variants to the current
/// collection's selection"），旧脚本只加不减 → UI 提示"已在 C1 中显示 N 张"与 C1
/// 实际选中（旧选中 + N）不符。sdef:1967 有配对的 deselect（直接参数同样是 document、
/// variants 是具名参数），因此 select 前必须先清掉当前选中。
@Suite("C1BridgeWave4b 在 C1 中选中（R12 deselect-first）")
struct C1BridgeWave4bDeselectFirstTests {
    @Test("select 脚本：先 deselect 当前选中，再 select（顺序固定）")
    func deselectsBeforeSelect() throws {
        let script = CaptureOneBridge.selectVariantsScript(
            appName: "Capture One", paths: ["/shoot/a.cr2", "/shoot/b.cr2"])
        // 当前选中经 application 级 selected variants 读出（与读取脚本同一对象归属）。
        #expect(script.contains("set previousSelection to selected variants"))
        #expect(script.contains("deselect targetDoc variants previousSelection"))
        #expect(script.contains("select targetDoc variants variantsToSelect"))
        let deselect = try #require(script.range(of: "deselect targetDoc variants previousSelection"))
        let select = try #require(script.range(of: "select targetDoc variants variantsToSelect"))
        #expect(deselect.lowerBound < select.lowerBound, "deselect 必须在 select 之前执行")
    }

    @Test("deselect 失败是受控降级：包在 try 里，不让整次「显示」变成脚本失败")
    func deselectFailureIsControlled() throws {
        let script = CaptureOneBridge.selectVariantsScript(
            appName: "Capture One", paths: ["/shoot/a.cr2"])
        // 清选中失败不能让 selectVariants 抛 C1_SCRIPT_FAILED（那会落到 open -a 导入）。
        let guardRange = try #require(
            script.range(of: "if (count of previousSelection) > 0 then"))
        let deselectRange = try #require(
            script.range(of: "deselect targetDoc variants previousSelection"))
        let tryRange = try #require(script.range(
            of: "try", range: guardRange.upperBound..<script.endIndex))
        #expect(tryRange.lowerBound < deselectRange.lowerBound)
        // 空选中/读不到选中时也走同一条受控路径（空列表按空处理，不报错）。
        #expect(script.contains("set previousSelection to {}"))
    }
}


// MARK: - Wave5 / R1+R3：写回报告 → UI 提示（多变体 / 不在当前集合）

/// Wave5：报告字段 consumed by UI —— 多变体与「不在当前集合」必须是两句不同的可执行提示。
/// 桥用固定报告替身：本套件只测报告 → UI 文案的映射，不碰脚本。
private struct Wave5ReportBridge: CaptureOneBridging {
    let report: C1VariantWritebackReport
    func selectedPhotoPaths() async throws -> [String] { [] }
    func reloadMetadata(sessionId: String) async throws {}
    func checkHealth() async -> Result<String, CaptureOneBridgeError> { .success("fake") }
    func preflight() async -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: true, appRunning: true, automationAuthorized: true,
            documentOpen: true, timedOut: false, appName: "Capture One")
    }
    nonisolated static func documentProbeScript(appName: String) -> String { "wave5:" + appName }
    func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport { report }
}

@MainActor
private func makeWave5CullingVM(bridge: Wave5ReportBridge) -> CullingViewModel {
    CullingViewModel(
        sessionId: "s1",
        culling: B8CullingAPIStub(),
        navigation: B8NavigationAPIStub(),
        metadata: B6bMetadataAPIStub(),
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: bridge)
}

@Suite("C1BridgeWave5 写回报告 → UI 提示（R1/R3）")
@MainActor
struct C1BridgeWave5WritebackNoticeTests {
    @Test("R1：多变体未写回 → 明说「回 C1 选变体重试或写回 XMP」，且不谎报全成功")
    func multiVariantNotice() async {
        let bridge = Wave5ReportBridge(report: C1VariantWritebackReport(
            written: 1, skippedMultiVariant: ["/shoot/b.cr2"]))
        let vm = makeWave5CullingVM(bridge: bridge)
        vm.page = b8CullingPage([b8CullingAsset("a"), b8CullingAsset("b")])
        vm.selectedPhotoIds = ["a", "b"]
        await vm.writeVariantJudgementsToCaptureOne()
        // 可执行提示落在 errorMessage（notice 只报计数）。
        #expect(vm.errorMessage?.code.contains("多变体未写回") == true)
        #expect(vm.errorMessage?.params == ["1"])
        guard case .text(let text)? = vm.notice?.payload else {
            Issue.record("期望文本 notice，实际 \(String(describing: vm.notice))")
            return
        }
        // 计数顺序：written / skippedMultiVariant / notFound / skipped。
        #expect(text.params == ["1", "1", "0", "0"])
        #expect(text.key.contains("多变体未写回"))
    }

    @Test("R3：notFound → 明说「C1 当前集合未包含这些照片」")
    func notFoundNotice() async {
        let bridge = Wave5ReportBridge(report: C1VariantWritebackReport(
            written: 0, notFound: ["/shoot/a.cr2"]))
        let vm = makeWave5CullingVM(bridge: bridge)
        vm.page = b8CullingPage([b8CullingAsset("a")])
        vm.selectedPhotoIds = ["a"]
        await vm.writeVariantJudgementsToCaptureOne()
        #expect(vm.errorMessage?.code.contains("C1 当前集合未包含这些照片") == true)
    }
}

// MARK: - latestScanJob 稳定选择

private func wave4bJob(
    id: String,
    updatedAt: String,
    status: AnalysisJobStatus = .running,
    sessionId: String = "s1",
    type: AnalysisJobType = .metadataScan
) -> AnalysisJobData {
    AnalysisJobData(
        id: id,
        type: type,
        scopeType: "session",
        scopeId: sessionId,
        dedupeKey: "\(type.rawValue):\(sessionId)",
        status: status,
        priority: 0,
        progressCurrent: 0,
        progressTotal: 0,
        progressMessage: "",
        inputFingerprint: "",
        modelId: "",
        modelVersion: "",
        checkpoint: [:],
        attemptCount: 0,
        leaseOwner: "",
        heartbeatAt: "",
        errorCode: "",
        errorMessage: "",
        createdAt: updatedAt,
        startedAt: "",
        finishedAt: "",
        updatedAt: updatedAt)
}

@Suite("C1BridgeWave4b scan job 稳定选择")
struct C1BridgeWave4bScanJobOrderingTests {
    @Test("同毫秒并列用 id 做稳定 tie-break；过滤其它会话/类型")
    func picksDeterministically() {
        let sameTime = "2026-11-11T08:00:00.000Z"
        let jobs = [
            wave4bJob(id: "job-a", updatedAt: sameTime, status: .running),
            wave4bJob(id: "job-b", updatedAt: sameTime, status: .succeeded),
            wave4bJob(id: "job-c", updatedAt: "2026-11-11T07:00:00.000Z", status: .failed),
            wave4bJob(id: "job-x", updatedAt: "2026-11-11T09:00:00.000Z", sessionId: "other"),
            wave4bJob(id: "job-y", updatedAt: "2026-11-11T09:00:00.000Z", type: .thumbnailBuild),
        ]
        #expect(C1ScanJobSelection.latestScanStatus(jobs: jobs, sessionId: "s1")
            == AnalysisJobStatus.succeeded.rawValue)
        #expect(C1ScanJobSelection.latestScanStatus(jobs: [], sessionId: "s1") == nil)
        #expect(C1ScanJobSelection.latestScanStatus(
            jobs: [wave4bJob(id: "only", updatedAt: sameTime)],
            sessionId: "missing") == nil)
    }
}

// MARK: - Hot Folder / 安装判定

@Suite("C1BridgeWave4b Hot Folder 安装判定")
struct C1BridgeWave4bInstalledTests {
    @Test("c1Installed 走注入接缝；协议默认 false（未接线不显示 C1 专属提示）")
    func installedFlag() {
        #expect(CaptureOneBridge(isC1Installed: { true }).c1Installed)
        #expect(!CaptureOneBridge(isC1Installed: { false }).c1Installed)
        #expect(!Wave4bStubBridge().c1Installed)
    }
}

private struct Wave4bStubBridge: CaptureOneBridging {
    func selectedPhotoPaths() async throws -> [String] { [] }
    func reloadMetadata(sessionId: String) async throws {}
    func checkHealth() async -> Result<String, CaptureOneBridgeError> { .success("stub") }
    func preflight() async -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: false, appRunning: false, automationAuthorized: false,
            documentOpen: false, timedOut: false)
    }
    nonisolated static func documentProbeScript(appName: String) -> String { "stub:" + appName }
}

// MARK: - MetadataSyncBar：待重载判定 + 动作注入

@Suite("C1BridgeWave4b MetadataSyncBar")
@MainActor
struct C1BridgeWave4bMetadataSyncBarTests {
    @Test("待 C1 重载 = requiresReloadAck && written>0（ack 已写后不再显示）")
    func awaitingAckFormula() {
        #expect(MetadataSyncBar.shouldWaitForReloadAck(
            requiresReloadAck: true, written: 1))
        #expect(!MetadataSyncBar.shouldWaitForReloadAck(
            requiresReloadAck: false, written: 1))
        #expect(!MetadataSyncBar.shouldWaitForReloadAck(
            requiresReloadAck: true, written: 0))
    }

    @Test("C1 动作注入后无环境工作区也可用；未注入时不可用")
    func injectedActionsWorkWithoutWorkspace() {
        let actions = MetadataSyncBarC1Actions(
            reload: {},
            acknowledgeManualLoad: {})
        let bar = MetadataSyncBar(
            sessionId: "s1", api: B6bMetadataAPIStub(), c1Actions: actions)
        #expect(bar.c1ActionsAvailable)
        let envOnly = MetadataSyncBar(sessionId: "s1", api: B6bMetadataAPIStub())
        #expect(!envOnly.c1ActionsAvailable)
    }
}
