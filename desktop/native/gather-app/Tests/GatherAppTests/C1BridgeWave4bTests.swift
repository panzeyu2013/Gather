// desktop/native/gather-app/Tests/GatherAppTests/C1BridgeWave4bTests.swift
// Wave4b / task-41 回归（C1 P2）：自动 reload 先 select 写盘照片、primary variant 回退文案、
// malformed 行计数、latestScanJob 稳定选择、Hot Folder 安装判定、MetadataSyncBar 动作注入。
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
