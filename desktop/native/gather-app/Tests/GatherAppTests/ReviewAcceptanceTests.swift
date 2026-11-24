// 第三轮全仓审查的**验收测试**（审查员探针原样收录）。
//
// 这些探针当初以「故意断言正确行为」的方式失败，从而暴露 1/2/4/5/6 号问题；
// 修复后它们必须全部通过——通过即视为对应验收标准达成。
//
// P1-6（ADR-028 未接线资产删除）：原「模型包完整性（问题 9）」3 条用例随
// 模型下载器一并下线；同批还删掉了 DeepModelAcceptanceTests.swift 整文件
//（唯一用例只测下载器的整包回滚）。
//
import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost
@MainActor @Suite("FullScan gallery navigation probe") struct FullScanNavigationProbeTests {
 @Test func galleryBackMustReturnToControl() {
  let nav = RootNavigation(); nav.openSession("s1"); nav.openGallery("s1"); nav.backFromGallery()
  #expect(nav.isSessionPage(sessionId: "s1", page: .control))
 }
}


// MARK: 第三轮验收：管道排空（问题 7）

@Suite("第三轮验收：子进程管道")
struct ReviewAcceptanceProcessTests {
    @Test("问题 7：子进程 stdout 超过管道容量也必须完成（不依赖 terminationHandler 读取）")
    func largeStdoutDoesNotDeadlock() async throws {
        let bridge = CaptureOneBridge()
        // 200,000 字节（远超 pipe 缓冲 ~64KB），旧实现会卡死到超时。
        let output = try await bridge.runProcess(
            executable: "/usr/bin/awk",
            arguments: ["BEGIN { for (i = 0; i < 200000; i++) printf \"x\" }"],
            timeout: 10
        )
        #expect(output.count == 200000, "大输出必须被完整排空（实际 \(output.count) 字节）")
    }

    @Test("问题 7：stderr 大输出 + 非零退出也要返回失败而不挂死")
    func largeStderrDoesNotDeadlock() async throws {
        let bridge = CaptureOneBridge()
        do {
            _ = try await bridge.runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "awk 'BEGIN { for (i = 0; i < 200000; i++) printf \"e\" > \"/dev/stderr\" }'; exit 3"],
                timeout: 10
            )
            Issue.record("非零退出必须抛错")
        } catch {
            // 期望：拿到错误（而不是超时挂死）；错误信息非空。
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}
