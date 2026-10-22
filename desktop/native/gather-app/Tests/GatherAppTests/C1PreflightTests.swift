// Dashboard C1 预检门控单测：对齐 tests/unit/renderer/c1-preflight.test.ts
// （四层检查门控、单格失败阻塞、guidance 优先级、超时追加格、整体失败兜底）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

@Suite("C1PreflightResult.build（对齐 c1-preflight.test.ts）")
struct C1PreflightTests {
    private func status(
        reachable: Bool = true,
        appRunning: Bool = true,
        automationAuthorized: Bool = true,
        documentOpen: Bool = true,
        timedOut: Bool = false
    ) -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: reachable,
            appRunning: appRunning,
            automationAuthorized: automationAuthorized,
            documentOpen: documentOpen,
            timedOut: timedOut
        )
    }

    @Test("四层全过 → 通过，无失败键，恰好 4 格")
    func allPassing() {
        let r = C1PreflightResult.build(from: status())
        #expect(r.passed == true)
        #expect(r.checks.count == 4)
        #expect(r.checks.allSatisfy { $0.passed })
        #expect(r.guidance == nil)
        // 4b-2e：检查项文案是 LocalizedText（VM 不读进程语言），渲染期按显式语言解析。
        let zhText = r.checks[0].label.resolve(with: L10n(language: .zhCN))
        let enText = r.checks[0].label.resolve(with: L10n(language: .en))
        #expect(zhText == "可连接 Capture One（AppleScript）")
        #expect(enText == "Can Connect to Capture One (AppleScript)")
        #expect(zhText != enText, "VM 不得在构建时锁死语言")
    }

    @Test("任意单格失败均阻塞导入且报出键")
    func anySingleFailureBlocks() {
        let cases: [(C1PreflightStatus, String)] = [
            (status(reachable: false), "reachable"),
            (status(appRunning: false), "appRunning"),
            (status(documentOpen: false), "documentOpen"),
            (status(automationAuthorized: false), "automationAuthorized"),
        ]
        for (s, key) in cases {
            let r = C1PreflightResult.build(from: s)
            #expect(r.passed == false)
            #expect(r.checks.first { $0.key == key && !$0.passed } != nil)
        }
    }

    @Test("guidance 优先级：timeout > reachable > automationAuthorized > appRunning > documentOpen")
    func guidancePriority() {
        // 4b-2e：guidance 是 LocalizedText（VM 不读进程语言），渲染期用显式 L10n 解析。
        let zh = L10n(language: .zhCN)
        // 超时优先于其他失败。
        let timeout = C1PreflightResult.build(from: status(reachable: false, timedOut: true))
        #expect(timeout.guidance?.resolve(with: zh) == "检测超时，请重试")
        let reachable = C1PreflightResult.build(from: status(reachable: false))
        #expect(reachable.guidance?.resolve(with: zh).contains("AppleScript") == true)
        let automation = C1PreflightResult.build(from: status(automationAuthorized: false))
        #expect(automation.guidance?.resolve(with: zh).contains("自动化") == true)
        let app = C1PreflightResult.build(from: status(appRunning: false))
        #expect(app.guidance?.resolve(with: zh).contains("启动 Capture One") == true)
        let doc = C1PreflightResult.build(from: status(documentOpen: false))
        #expect(doc.guidance?.resolve(with: zh).contains("文档") == true)
    }

    @Test("超时额外追加一格（5 格）")
    func timeoutAddsCheck() {
        let r = C1PreflightResult.build(from: status(timedOut: true))
        #expect(r.checks.count == 5)
        #expect(r.passed == false)
        #expect(r.checks.contains { $0.key == "timeout" && !$0.passed })
    }

    @Test("整体失败兜底：四层全失败（TS failedC1Preflight）")
    func failedFallback() {
        let r = C1PreflightResult.failed()
        #expect(r.passed == false)
        #expect(r.checks.count == 4)
        #expect(r.checks.allSatisfy { !$0.passed })
    }
}
