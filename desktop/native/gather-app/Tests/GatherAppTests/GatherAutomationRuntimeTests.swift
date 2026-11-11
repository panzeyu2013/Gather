// desktop/native/gather-app/Tests/GatherAppTests/GatherAutomationRuntimeTests.swift
// Wave3 / task-21：Shortcuts/App Intents 运行时注册表与动作返回形状。
//
// 覆盖：
// 1. 未安装时 current == nil（App Intents 走 runtimeUnavailable）；
// 2. install 后四个动作闭包按注入实现返回（intents 只依赖这些闭包，不需要真库）；
// 3. reset 清空。
//
// 边界：不启动 AppBootstrap、不打开 SQLite；只验证注册表与闭包装配面。
import Foundation
import Testing
@testable import GatherHost
@testable import GatherProtocol

@Suite("Shortcuts 运行时注册表", .serialized)
struct GatherAutomationRuntimeTests {
    @Test func registryStartsEmptyThenInstallsAndResets() async throws {
        GatherAutomationRuntimeRegistry.reset()
        #expect(GatherAutomationRuntimeRegistry.current == nil)

        let runtime = GatherAutomationRuntime(
            createWorkspaceAndImport: { _, _ in "session-1" },
            exportSession: { _, _, _, _, _ in
                ExportResult(totalFiles: 2, exported: 2, failed: 0, skipped: 0, errors: [])
            },
            writebackMetadata: { sessionId, target in
                GatherAutomationWritebackSummary(
                    sessionId: sessionId, target: target,
                    written: 3, failed: 0, skipped: 1)
            },
            sessionStatus: { sessionId in
                GatherAutomationSessionStatus(
                    sessionId: sessionId, name: "WS", photoCount: 10,
                    pendingXmp: 0, writtenXmp: 10, failedXmp: 0,
                    conflictXmp: 0, reloadAckedAt: "2026-11-11T00:00:00Z")
            })
        GatherAutomationRuntimeRegistry.current = runtime
        let installed = try #require(GatherAutomationRuntimeRegistry.current)

        let created = try await installed.createWorkspaceAndImport(
            "workspace", ["/tmp/a.jpg", "/tmp/b.jpg"])
        #expect(created == "session-1")

        let export = try await installed.exportSession(
            "session-1", "/tmp/export", "jpeg", 0.9, 2000)
        #expect(export.exported == 2)

        let writeback = try await installed.writebackMetadata("session-1", "rating")
        #expect(writeback.written == 3)

        let status = try await installed.sessionStatus("session-1")
        #expect(status.photoCount == 10)

        GatherAutomationRuntimeRegistry.reset()
        #expect(GatherAutomationRuntimeRegistry.current == nil)
    }

    @Test func unavailableErrorCarriesDescription() {
        #expect(GatherAutomationError.runtimeUnavailable.errorDescription?.isEmpty == false)
        #expect(GatherAutomationError.noFiles.errorDescription?.isEmpty == false)
    }
}
